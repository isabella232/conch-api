use utf8;
package Conch::DB::Result::DeviceLocation;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Conch::DB::Result::DeviceLocation

=cut

use strict;
use warnings;


=head1 BASE CLASS: L<Conch::DB::Result>

=cut

use base 'Conch::DB::Result';

=head1 TABLE: C<device_location>

=cut

__PACKAGE__->table("device_location");

=head1 ACCESSORS

=head2 device_id

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 0

=head2 rack_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 rack_unit_start

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 created

  data_type: 'timestamp with time zone'
  default_value: current_timestamp
  is_nullable: 0
  original: {default_value => \"now()"}

=head2 updated

  data_type: 'timestamp with time zone'
  default_value: current_timestamp
  is_nullable: 0
  original: {default_value => \"now()"}

=cut

__PACKAGE__->add_columns(
  "device_id",
  { data_type => "text", is_foreign_key => 1, is_nullable => 0 },
  "rack_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "rack_unit_start",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "created",
  {
    data_type     => "timestamp with time zone",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
  },
  "updated",
  {
    data_type     => "timestamp with time zone",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
  },
);

=head1 PRIMARY KEY

=over 4

=item * L</device_id>

=back

=cut

__PACKAGE__->set_primary_key("device_id");

=head1 UNIQUE CONSTRAINTS

=head2 C<device_location_rack_id_rack_unit_start_key>

=over 4

=item * L</rack_id>

=item * L</rack_unit_start>

=back

=cut

__PACKAGE__->add_unique_constraint(
  "device_location_rack_id_rack_unit_start_key",
  ["rack_id", "rack_unit_start"],
);

=head1 RELATIONS

=head2 datacenter_rack

Type: belongs_to

Related object: L<Conch::DB::Result::DatacenterRack>

=cut

__PACKAGE__->belongs_to(
  "datacenter_rack",
  "Conch::DB::Result::DatacenterRack",
  { id => "rack_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);

=head2 datacenter_rack_layout

Type: belongs_to

Related object: L<Conch::DB::Result::DatacenterRackLayout>

=cut

__PACKAGE__->belongs_to(
  "datacenter_rack_layout",
  "Conch::DB::Result::DatacenterRackLayout",
  { rack_id => "rack_id", rack_unit_start => "rack_unit_start" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);

=head2 device

Type: belongs_to

Related object: L<Conch::DB::Result::Device>

=cut

__PACKAGE__->belongs_to(
  "device",
  "Conch::DB::Result::Device",
  { id => "device_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2018-09-25 12:35:59
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:3xAQAIa80SkxrqIVgC6eyA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
__END__

=pod

=head1 LICENSING

Copyright Joyent, Inc.

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at http://mozilla.org/MPL/2.0/.

=cut
