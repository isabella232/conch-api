package Conch::Controller::HardwareProduct;

use Mojo::Base 'Mojolicious::Controller', -signatures;

=pod

=head1 NAME

Conch::Controller::HardwareProduct

=head1 METHODS

=head2 list

Get a list of all available hardware products.

Response uses the HardwareProducts json schema.

=cut

sub list ($c) {
    my @hardware_products_raw = $c->db_hardware_products
        ->active
        ->order_by('name')
        ->all;

    $c->status(200, \@hardware_products_raw);
}

=head2 find_hardware_product

Chainable action that uses the C<hardware_product_id> or C<hardware_product_key> and
C<hardware_product_value> values provided in the stash (usually via the request URL) to look up
a hardware_product, and stashes the query to get to it in C<hardware_product_rs>.

Supported keys are: C<sku>, C<name>, and C<alias>.

=cut

sub find_hardware_product ($c) {
    my $hardware_product_rs = $c->db_hardware_products;

    # route restricts key to: sku, name, alias
    if (my $key = $c->stash('hardware_product_key')
            and my $value = $c->stash('hardware_product_value')) {
        $c->log->debug('Looking up a HardwareProduct by identifier ('.$key.' = '.$value.')');
        $hardware_product_rs = $hardware_product_rs
            ->search({ 'hardware_product.'.$key => $value });
    }
    elsif ($c->stash('hardware_product_id')) {
        $c->log->debug('Looking up a HardwareProduct by id '.$c->stash('hardware_product_id'));
        $hardware_product_rs = $hardware_product_rs
            ->search({ 'hardware_product.id' => $c->stash('hardware_product_id') });
    }
    else {
        return $c->status(500);
    }

    if (not $hardware_product_rs->exists) {
        $c->log->debug('Could not find hardware product with '
            .($c->stash('hardware_product_id') ? ('id '.$c->stash('hardware_product_id'))
                : ($c->stash('hardware_product_key').' '.$c->stash('hardware_product_value'))));
        return $c->status(404);
    }

    $hardware_product_rs = $hardware_product_rs->active;
    if (not $hardware_product_rs->exists) {
        $c->log->debug('Hardware product '
            .($c->stash('hardware_product_id') ? ('id '.$c->stash('hardware_product_id'))
                : ($c->stash('hardware_product_key').' '.$c->stash('hardware_product_value')))
            .'has already been deactivated');
        return $c->status(410);
    }

    $c->stash('hardware_product_rs', $hardware_product_rs);
    return 1;
}

=head2 get

Get the details of a single hardware product.

Response uses the HardwareProduct json schema.

=cut

sub get ($c) {
    $c->status(200, $c->stash('hardware_product_rs')->single);
}

=head2 create

Creates a new hardware_product.

=cut

sub create ($c) {
    my $input = $c->validate_request('HardwareProductCreate');
    return if not $input;

    for my $key (qw(name alias sku)) {
        next if not $input->{$key};
        if ($c->db_hardware_products->active->search({ $input->%{$key} })->exists) {
            $c->log->debug('Failed to create hardware product: unique constraint violation for '.$key);
            return $c->status(409, { error => "Unique constraint violated on '$key'" });
        }
    }

    for my $key (qw(hardware_vendor_id validation_plan_id)) {
        (my $rs_name = $key) =~ s/_id$/s/; $rs_name = 'db_'.$rs_name;
        return $c->status(409, { error => $key.' does not exist' })
            if not $c->$rs_name->active->search({ id => $input->{$key} })->exists;
    }

    my $hardware_product = $c->txn_wrapper(sub ($c) {
        $c->db_hardware_products->create($input);
    });

    # if the result code was already set, we errored and rolled back the db..
    return $c->status(400) if not $hardware_product;

    $c->log->debug('Created hardware product id '.$hardware_product->id);
    $c->status(303, '/hardware_product/'.$hardware_product->id);
}

=head2 update

Updates an existing hardware_product.

=cut

sub update ($c) {
    my $input = $c->validate_request('HardwareProductUpdate');
    return if not $input;

    my $hardware_product = $c->stash('hardware_product_rs')->single;

    for my $key (qw(name alias sku)) {
        next if not defined $input->{$key};
        next if $input->{$key} eq $hardware_product->$key;

        if ($c->db_hardware_products->active->search({ $input->%{$key} })->exists) {
            $c->log->debug('Failed to create hardware product: unique constraint violation for '.$key);
            return $c->status(409, { error => "Unique constraint violated on '$key'" });
        }
    }

    for my $key (qw(hardware_vendor_id validation_plan_id)) {
        next if not exists $input->{$key};
        next if $input->{$key} eq $hardware_product->$key;
        (my $rs_name = $key) =~ s/_id$/s/; $rs_name = 'db_'.$rs_name;
        return $c->status(409, { error => $key.' does not exist' })
            if not $c->$rs_name->active->search({ id => $input->{$key} })->exists;
    }

    $c->txn_wrapper(sub ($c) {
        $hardware_product->update({ $input->%*, updated => \'now()' }) if keys $input->%*;
        $c->log->debug('Updated hardware product '.$hardware_product->id);
        return 1;
    })
    or return $c->res->code(400);

    $c->status(303, '/hardware_product/'.$hardware_product->id);
}

=head2 delete

=cut

sub delete ($c) {
    my $id = $c->stash('hardware_product_rs')->get_column('id')->single;
    $c->stash('hardware_product_rs')->deactivate;

    $c->log->debug('Deleted hardware product '.$id);
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
