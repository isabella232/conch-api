package Conch::Controller::RackRole;

use Mojo::Base 'Mojolicious::Controller', -signatures;

=pod

=head1 NAME

Conch::Controller::RackRole

=head1 METHODS

=head2 find_rack_role

Supports rack role lookups by uuid and name.

=cut

sub find_rack_role ($c) {
    my $rack_role;
    if ($c->stash('rack_role_id_or_name') =~ /^(.+?)\=(.+)$/) {
        my ($key, $value) = ($1, $2);
        if ($key ne 'name') {
            $c->log->warn("Unknown identifier '$key'");
            return $c->status(404);
        }

        $c->log->debug("Looking up rack role using identifier '$key'");
        $rack_role = $c->db_rack_roles->find({ name => $value }, { key => 'rack_role_name_key' });
    }
    else {
        $c->log->debug('looking up rack role by id');
        $rack_role = $c->db_rack_roles->find($c->stash('rack_role_id_or_name'));
    }

    if (not $rack_role) {
        $c->log->debug('Failed to find rack role');
        return $c->status(404);
    }

    $c->log->debug('Found rack role '.$rack_role->id);
    $c->stash('rack_role', $rack_role);
    return 1;
}

=head2 create

Create a new rack role.

=cut

sub create ($c) {
    my $input = $c->validate_request('RackRoleCreate');
    return if not $input;

    if ($c->db_rack_roles->search({ name => $input->{name} })->exists) {
        $c->log->debug("Name conflict on '".$input->{name}."'");
        return $c->status(409, { error => 'name is already taken' });
    }

    my $rack_role = $c->db_rack_roles->create($input);
    $c->log->debug('Created rack role '.$rack_role->id);
    $c->status(303, '/rack_role/'.$rack_role->id);
}

=head2 get

Get a single rack role.

Response uses the RackRole json schema.

=cut

sub get ($c) {
    $c->status(200, $c->stash('rack_role'));
}

=head2 get_all

Get all rack roles.

Response uses the RackRoles json schema.

=cut

sub get_all ($c) {
    my @rack_roles = $c->db_rack_roles->order_by('name')->all;
    $c->log->debug('Found '.scalar(@rack_roles).' rack roles');

    $c->status(200, \@rack_roles);
}

=head2 update

Modify an existing rack role.

=cut

sub update ($c) {
    my $input = $c->validate_request('RackRoleUpdate');
    return if not $input;

    if ($input->{name}) {
        if ($c->db_rack_roles->search({ name => $input->{name} })->exists) {
            $c->log->debug("Name conflict on '".$input->{name}."'");
            return $c->status(409, { error => 'name is already taken' });
        }
    }

    my $rack_role = $c->stash('rack_role');

    # prohibit shrinking rack_size if there are layouts that extend beyond it
    if ($input->{rack_size}) {
        my $rack_rs = $rack_role->related_resultset('racks');

        while (my $rack = $rack_rs->next) {
            my %assigned_rack_units = map +($_ => 1),
                $rack->self_rs->assigned_rack_units;
            my @assigned_rack_units = sort { $a <=> $b } keys %assigned_rack_units;

            if (my @out_of_range = grep $_ > $input->{rack_size}, @assigned_rack_units) {
                $c->log->debug('found layout used by rack_role id '.$rack_role->id
                    .' that has assigned rack_units greater requested new rack_size of '
                    .$input->{rack_size}.': ', join(', ', @out_of_range));
                return $c->status(409, { error => 'cannot resize rack_role: found an assigned rack layout that extends beyond the new rack_size' });
            }
        }
    }

    $rack_role->set_columns($input);
    $rack_role->update({ updated => \'now()' }) if $rack_role->is_changed;
    $c->log->debug('Updated rack role '.$rack_role->id);
    $c->status(303, '/rack_role/'.$rack_role->id);
}

=head2 delete

Delete a rack role.

=cut

sub delete ($c) {
    if ($c->stash('rack_role')->related_resultset('racks')->exists) {
        $c->log->debug('Cannot delete rack_role: in use by one or more racks');
        return $c->status(409, { error => 'cannot delete a rack_role when a rack is referencing it' });
    }

    $c->stash('rack_role')->delete;
    $c->log->debug('Deleted rack role '.$c->stash('rack_role')->id);
    return $c->status(204);
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
