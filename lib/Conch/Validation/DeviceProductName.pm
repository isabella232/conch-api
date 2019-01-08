package Conch::Validation::DeviceProductName;

use Mojo::Base 'Conch::Validation';

use constant name        => 'product_name';
use constant version     => 1;
use constant category    => 'BIOS';
use constant description => q(Validate reported product name matches product name expected in rack layout);


sub validate {
	my ( $self, $data ) = @_;

	unless($data->{product_name}) {
		$self->die("Missing 'product_name' property");
	}

	# TODO: be more vigorous in the checking:
	# verify that $device->hardware_product_id
	# eq $device->device_location->datacenter_rack_layout->hardware_product_id

	# We do not currently define a Conch or Joyent specific name for
	# switches. This may change in the future, but currently we continue
	# to use the vendor product ID.
	if ($data->{device_type} && $data->{device_type} eq "switch") {
		$self->register_result(
			expected => $self->hardware_product_name,
			got      => $data->{product_name},
		);
		return;
	}

	# Previous iterations of our hardware naming are still in the field
	# and cannot be updated to the new style. Continue to support them.
	if(
		($data->{product_name} =~ /^Joyent-Compute/) or
		($data->{product_name} =~ /^Joyent-Storage/)
	) {
		$self->register_result(
			expected => $self->hardware_legacy_product_name,
			got      => $data->{product_name},
		);
	} else {
		$self->register_result(
			expected => $self->hardware_product_generation,
			got      => $data->{product_name},
		);
	}
}

1;
__END__

=pod

=head1 LICENSING

Copyright Joyent, Inc.

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at http://mozilla.org/MPL/2.0/.

=cut
