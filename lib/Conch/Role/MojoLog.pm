=head1 NAME

Conch::Role::MojoLog - Provide logging to a Mojo controllers

=head1 DESCRIPTION

This role provides a log method for a Mojo controller that adds additional
context to the logs

=head1 SYNOPSIS

    use Role::Tiny::With;
    with 'Conch::Role::MojoLog';

    sub wat ($c) {
        $c->log->debug('message');
    }

=head1 METHODS

=cut

package Conch::Role::MojoLog;
use Mojo::Base -role;

=head2 log

The logger itself. The usual levels are available, like debug, warn, etc.

=cut

has log => sub {
    my $c = shift;
    my $home = $c->app->home;
    my $mode = $c->app->mode;

    my %args = (
        request_id => $c->req->request_id,
        level      => 'debug',
    );
    if (not $c->feature('log_to_stderr')) {
        $args{path} = $home->child('log', "$mode.log"),
    }

    return Conch::Log->new(%args);
};

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
