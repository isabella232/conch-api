package Conch::Controller::Login;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Conch::UUID 'is_uuid';
use Time::HiRes ();
use Authen::Passphrase::RejectAll;

=pod

=head1 NAME

Conch::Controller::Login

=head1 METHODS

=head2 _respond_with_jwt

Create a response containing a login JWT, which the user should later present in the
'Authorization Bearer' header.

=cut

sub _respond_with_jwt ($c, $user_id, $expires_delta = undef) {
    my $jwt_config = $c->app->config('jwt') || {};

    my $expires_abs = time + (
        defined $expires_delta ? $expires_delta
            # system admin default: 30 days
      : $c->is_system_admin ? ($jwt_config->{system_admin_expiry} || 2592000)
            # normal default: 1 day
      : ($jwt_config->{normal_expiry} || 86400));

    my ($session_token, $jwt) = $c->generate_jwt(
        $user_id,
        $expires_abs,
        'login_jwt_'.join('_', Time::HiRes::gettimeofday), # reasonably unique name
    );

    return if $c->res->code;
    return $c->status(200, { jwt_token => $jwt });
}

=head2 authenticate

Handle the details of authenticating the user, with one of the following options:

 * existing session for the user
 * signed JWT in the Authorization Bearer header
 * Old 'conch' session cookie

Does not terminate the connection if authentication is successful, allowing for chaining to
subsequent routes and actions.

=cut

sub authenticate ($c) {
    if (my $user = $c->stash('user')) {
        $c->log->debug('already authenticated (user '.$user->name.')');
        return 1;
    }

    my ($user_id, $session_token);
    if ($c->req->headers->authorization
        && $c->req->headers->authorization =~ /^Bearer (.+)/)
    {
        $c->log->debug('attempting to authenticate with Authorization: Bearer header...');
        my $token = $1;

        # Attempt to decode with every configured secret, in case JWT token was
        # signed with a rotated secret
        my $jwt_claims;
        for my $secret ($c->app->secrets->@*) {
            # Mojo::JWT->decode blows up if the token is invalid
            $jwt_claims = eval { Mojo::JWT->new(secret => $secret)->decode($token) } and last;
        }

        if (not $jwt_claims or not $jwt_claims->{user_id} or not is_uuid($jwt_claims->{user_id}
                or not $jwt_claims->{token_id} or not is_uuid($jwt_claims->{token_id}
                or not $jwt_claims->{exp} or $jwt_claims->{exp} !~ /^[0-9]+$/))) {
            $c->log->debug('auth failed: JWT could not be decoded');
            return $c->status(401);
        }

        $user_id = $jwt_claims->{user_id};

        if ($jwt_claims->{exp} <= time) {
            $c->log->debug('auth failed: JWT for user_id '.$user_id.' has expired');
            return $c->status(401);
        }

        if (not $session_token = $c->db_user_session_tokens
                ->unexpired
                ->search({ id => $jwt_claims->{token_id}, user_id => $user_id })
                ->single) {
            $c->log->debug('auth failed: JWT for user_id '.$user_id.' could not be found');
            return $c->status(401);
        }

        $session_token->update({ last_used => \'now()' });
        $c->stash('token_id', $jwt_claims->{token_id});
    }

    if ($c->session('user')) {
        return $c->status(400, { error => 'user session is invalid' })
            if not is_uuid($c->session('user')) or ($user_id and $c->session('user') ne $user_id);
        $c->log->debug('using session user='.$c->session('user'));
        $user_id ||= $c->session('user');
    }

    # clear out all expired session tokens
    $c->db_user_session_tokens->expired->delete;

    if ($user_id) {
        if (my $user = $c->db_user_accounts->active->find($user_id)) {
            $c->log->debug('looking up user by id '.$user_id.': found '.$user->name. ' ('.$user->email.')');
            $user->update({ last_seen => \'now()' });

            # api tokens are exempt from this check
            if ((not $session_token or $session_token->is_login)
                    and $user->refuse_session_auth) {
                if ($user->force_password_change) {
                    if ($c->req->url ne '/user/me/password') {
                        $c->log->debug('attempt to authenticate before changing insecure password');

                        # ensure session and and all login JWTs expire in no more than 10 minutes
                        $c->session(expiration => 10 * 60);
                        $user->user_session_tokens->login_only
                            ->update({ expires => \'least(expires, now() + interval \'10 minutes\')' }) if $session_token;

                        $c->res->headers->location($c->url_for('/user/me/password'));
                        return $c->status(401);
                    }
                }
                else {
                    $c->log->debug('user\'s tokens were revoked - they must /login again');
                    return $c->status(401);
                }
            }

            $c->stash('user_id', $user_id);
            $c->stash('user', $user);
            return 1;
        }

        $c->log->debug('looking up user by id '.$user_id.': not found');
    }

    $c->log->debug('auth failed: no credentials provided');
    return $c->status(401);
}

=head2 session_login

Handles the act of logging in, given a user and password in the form.
Response uses the Login json schema, containing a JWT.

=cut

sub session_login ($c) {
    my $input = $c->validate_request('Login');
    return if not $input;

    my $user_rs = $c->db_user_accounts->active;
    my $user = $input->{user_id} ? $user_rs->find($input->{user_id})
        : $input->{email} ? $user_rs->find_by_email($input->{email})
        : undef;

    if (not $user) {
        $c->log->debug('user lookup for '.($input->{user}//$input->{email}).' failed');
        return $c->status(401);
    }

    if (not $user->check_password($input->{password})) {
        $c->log->debug('password validation for '.($input->{user}//$input->{email}).' failed');
        return $c->status(401);
    }

    $c->stash('user_id', $user->id);
    $c->stash('user', $user);

    $c->session(user => $user->id) if not $c->feature('stop_conch_cookie_issue');

    # clear out all expired session tokens
    $c->db_user_session_tokens->expired->delete;

    if ($user->force_password_change) {
        $c->log->info('user '.$user->name.' logging in with one-time insecure password');
        $user->update({
            last_login => \'now()',
            last_seen => \'now()',
            password => Authen::Passphrase::RejectAll->new, # ensure password cannot be used again
        });
        # password must be reset within 10 minutes
        $c->session(expires => time + 10 * 60);

        # we logged the user in, but he must now change his password (within 10 minutes)
        $c->res->headers->location($c->url_for('/user/me/password'));
        return $c->_respond_with_jwt($user->id, 10 * 60);
    }

    # allow the user to use session auth again
    $user->update({
        last_login => \'now()',
        last_seen => \'now()',
        refuse_session_auth => 0,
    });

    # reuse an existing JWT if one is suitable; otherwise generate a new one
    # where suitable = half its lifetime remains
    my $token_rs = $c->db_user_session_tokens
        ->login_only
        ->unexpired
        ->search({ user_id => $c->stash('user_id') })
        ->search(\[ '(expires - now()) >= (now() - created)' ]);
    if (my $token = $token_rs->order_by({ -desc => 'created' })->rows(1)->single) {
        return $c->status(200, { jwt_token => $c->generate_jwt_from_token($token) });
    }

    return $c->_respond_with_jwt($user->id);
}

=head2 session_logout

Logs a user out by expiring their session

=cut

sub session_logout ($c) {
    $c->session(expires => 1);

    # expire this user's token
    # (assuming we have the user's id, which we probably don't)
    if ($c->stash('user_id') and $c->stash('token_id')) {
        $c->db_user_session_tokens
            ->search({ id => $c->stash('token_id'), user_id => $c->stash('user_id') })
            ->unexpired
            ->expire;
    }

    # delete all expired session tokens
    $c->db_user_session_tokens->expired->delete;

    $c->status(204);
}

=head2 refresh_token

Refresh a user's JWT token. Deletes the old token and expires the session.

=cut

sub refresh_token ($c) {
    $c->validate_request('Null');
    return if $c->res->code;

    $c->session('expires', 1) if $c->session('user');

    $c->db_user_session_tokens
            ->search({ id => $c->stash('token_id'), user_id => $c->stash('user_id') })
            ->unexpired->expire
        if $c->stash('token_id');

    # clear out all expired session tokens
    $c->db_user_session_tokens->expired->delete;

    return $c->_respond_with_jwt($c->stash('user_id'));
}

1;
__END__

=pod

=head1 LICENSING

Copyright Joyent, Inc.

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at L<http://mozilla.org/MPL/2.0/>.

=cut
# vim: set ts=4 sts=4 sw=4 et :
