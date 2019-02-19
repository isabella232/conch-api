use Mojo::Base -strict;
use open ':std', ':encoding(UTF-8)'; # force stdin, stdout, stderr into utf8
use warnings FATAL => 'utf8';
use Test::More;
use Data::UUID;
use Path::Tiny;
use Test::Deep;
use Test::Deep::JSON;
use Test::Warnings;
use Mojo::JSON qw(from_json to_json);
use Test::Conch;

my $t = Test::Conch->new;
$t->load_fixture('legacy_datacenter');
$t->load_validation_plans([{
    name        => 'Conch v1 Legacy Plan: Server',
    description => 'Test Plan',
    validations => [ 'Conch::Validation::DeviceProductName' ],
}]);

my $uuid = Data::UUID->new;

$t->authenticate;

isa_ok( $t->tx->res->cookie('conch'), 'Mojo::Cookie::Response' );

$t->get_ok('/workspace')
	->status_is(200)
	->json_schema_is('WorkspacesAndRoles')
	->json_is( '/0/name', 'GLOBAL' );

my $global_ws_id = $t->tx->res->json->[0]{id};
BAIL_OUT("No workspace ID") unless $global_ws_id;

$t->post_ok(
	"/workspace/$global_ws_id/child" => json => {
		name        => "test",
		description => "also test",
	}
)->status_is(201);

my $sub_ws_id = $t->tx->res->json->{id};
BAIL_OUT("Could not create sub-workspace.") unless $sub_ws_id;

subtest 'Workspace Rooms' => sub {

	$t->get_ok("/workspace/$global_ws_id/room")
		->status_is(200)
		->json_schema_is('Rooms')
		->json_is('/0/az', 'test-region-1a');

	my $room_id = $t->tx->res->json->[0]->{id};
	my $room = $t->app->db_datacenter_rooms->find($room_id);
	my $new_room = $t->app->db_datacenter_rooms->create({
		datacenter_id => $room->datacenter_id,
		az => $room->az,
	});
	my $new_room_id = $new_room->id;

	$t->put_ok( "/workspace/$global_ws_id/room", json => [$room_id, $new_room_id])
		->status_is(400, 'Cannot modify GLOBAL' )
		->json_is({ error => 'Cannot modify GLOBAL workspace' });

	my $bad_room_id = $uuid->create_str;
	$t->put_ok( "/workspace/$sub_ws_id/room", json => [$bad_room_id, $new_room_id])
		->status_is(409, 'bad room ids')
		->json_is({ error => "Datacenter room IDs must be members of the parent workspace: $bad_room_id" });

	$t->put_ok("/workspace/$sub_ws_id/room", json => [$room_id, $new_room_id])
		->status_is( 200, 'Replaced datacenter rooms' )
		->json_schema_is('Rooms')
		->json_is('/0/id', $room_id)
		->json_is('/1/id', $new_room_id);

	$t->get_ok("/workspace/$sub_ws_id/room")
		->status_is(200)
		->json_schema_is('Rooms')
		->json_is('/0/id', $room_id)
		->json_is('/1/id', $new_room_id);

	$t->put_ok("/workspace/$sub_ws_id/room", json => [])
		->json_schema_is('Rooms')
		->status_is(200, 'Remove datacenter rooms')
		->json_is('', []);
};

subtest 'Device Report' => sub {
	# register the relay referenced by the report
	$t->post_ok('/relay/deadbeef/register',
		json => {
			serial   => 'deadbeef',
			version  => '0.0.1',
			ipaddr   => '127.0.0.1',
			ssh_port => '22',
			alias    => 'test relay'
		}
	)->status_is(204);

    # device reports are submitted thusly:
    # 0: pass
    # 1: pass (eventually deleted)
    # 2: pass
    # 3: - (invalid json)
    # 4: - (valid json, but does not pass the schema)
    # 5: pass
    # 6: error (empty product_name)
    # 7: pass

	my $good_report = path('t/integration/resource/passing-device-report.json')->slurp_utf8;
	$t->post_ok('/device/TEST', { 'Content-Type' => 'application/json' }, $good_report)
		->status_is(200)
		->json_schema_is('ValidationState')
		->json_cmp_deeply(superhashof({
			device_id => 'TEST',
			status => 'pass',
			completed => re(qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3,9}Z$/),
		}));

    my (@device_report_ids, @validation_state_ids);
    push @device_report_ids, $t->tx->res->json->{device_report_id};
    push @validation_state_ids, $t->tx->res->json->{id};

    my $device = $t->app->db_devices->find('TEST');
    cmp_deeply(
        $device->self_rs->latest_device_report->single,
        methods(
            id => $device_report_ids[0],
            device_id => 'TEST',
            report => json(from_json($good_report)),
            invalid_report => undef,
            retain => bool(1),    # first report is always saved
        ),
        'stored the report in raw form',
    );

	is($device->related_resultset('device_reports')->count, 1, 'one device_report row created');
	is($device->related_resultset('validation_states')->count, 1, 'one validation_state row created');
	is($t->app->db_validation_results->count, 1, 'one validation result row created');
	is($device->related_resultset('device_relay_connections')->count, 1, 'one device_relay_connection row created');


    # submit another passing report...
    $t->post_ok('/device/TEST', { 'Content-Type' => 'application/json' }, $good_report)
        ->status_is(200)
        ->json_schema_is('ValidationState')
        ->json_cmp_deeply(superhashof({
            device_id => 'TEST',
            status => 'pass',
            completed => re(qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3,9}Z$/),
        }));

    push @device_report_ids, $t->tx->res->json->{device_report_id};
    push @validation_state_ids, $t->tx->res->json->{id};

    is($device->related_resultset('device_reports')->count, 2, 'two device_report rows exist');
    is($device->related_resultset('validation_states')->count, 2, 'two validation_state rows exist');
    is($t->app->db_validation_results->count, 1, 'the second validation result is the same as the first');


    # submit another passing report (this makes 3)
    $t->post_ok('/device/TEST', { 'Content-Type' => 'application/json' }, $good_report)
        ->status_is(200)
        ->json_schema_is('ValidationState')
        ->json_cmp_deeply(superhashof({
            device_id => 'TEST',
            status => 'pass',
            completed => re(qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3,9}Z$/),
        }));

    push @device_report_ids, $t->tx->res->json->{device_report_id};
    push @validation_state_ids, $t->tx->res->json->{id};

    # now the 2nd of the 3 reports should be deleted.
    is($device->related_resultset('device_reports')->count, 2, 'still just two device_report rows exist');
    is($device->related_resultset('validation_states')->count, 2, 'still just two validation_state rows exist');
    is($t->app->db_validation_results->count, 1, 'still just one validation result row exists');

    ok(!$t->app->db_device_reports->search({ id => $device_report_ids[1] })->exists,
        'second device_report deleted');
    ok(!$t->app->db_validation_states->search({ id => $validation_state_ids[1] })->exists,
        'second validation_state deleted');


	my $invalid_json_1 = '{"this": 1s n0t v@l,d ǰsøƞ';	# } for brace matching
	$t->post_ok('/device/TEST', { 'Content-Type' => 'application/json; charset=utf-8' },
			Encode::encode('UTF-8', $invalid_json_1))
		->status_is(400);

	cmp_deeply(
		$device->self_rs->latest_device_report->single,
		methods(
			device_id => 'TEST',
			report => undef,
			invalid_report => $invalid_json_1,
		),
		'stored the invalid report in raw form',
	);

    # the device report was saved, but no validations run.
    push @device_report_ids, $t->app->db_device_reports->order_by({ -desc => 'created' })->rows(1)->get_column('id')->single;

    is($device->related_resultset('device_reports')->count, 3, 'now three device_report rows exist');
    is($device->related_resultset('validation_states')->count, 2, 'still just two validation_state rows exist');
    is($t->app->db_validation_results->count, 1, 'still just one validation result row exists');

	$t->get_ok('/device/TEST')
		->status_is(200)
		->json_schema_is('DetailedDevice')
		->json_is('/health' => 'PASS')
		->json_is('/latest_report_is_invalid' => JSON::PP::true)
		->json_is('/latest_report' => undef)
		->json_is('/invalid_report' => $invalid_json_1);


	my $invalid_json_2 = to_json({ foo => 'this 1s v@l,d ǰsøƞ, but violates the schema' });
	$t->post_ok('/device/TEST', { 'Content-Type' => 'application/json; charset=utf-8' },
			json => { foo => 'this 1s v@l,d ǰsøƞ, but violates the schema' })
		->status_is(400);

	cmp_deeply(
		$device->self_rs->latest_device_report->single,
		methods(
			device_id => 'TEST',
			invalid_report => $invalid_json_2,
		),
		'stored the invalid report in raw form',
	);

    # the device report was saved, but no validations run.
    push @device_report_ids, $t->app->db_device_reports->order_by({ -desc => 'created' })->rows(1)->get_column('id')->single;

    is($device->related_resultset('device_reports')->count, 4, 'now four device_report rows exist');
    is($device->related_resultset('validation_states')->count, 2, 'still just two validation_state rows exist');
    is($t->app->db_validation_results->count, 1, 'still just one validation result row exists');

	$t->get_ok('/device/TEST')
		->status_is(200)
		->json_schema_is('DetailedDevice')
		->json_is('/health' => 'PASS')
		->json_is('/latest_report_is_invalid' => JSON::PP::true)
		->json_is('/latest_report' => undef)
		->json_is('/invalid_report' => $invalid_json_2);


    # submit another passing report...
    $t->post_ok('/device/TEST', { 'Content-Type' => 'application/json' }, $good_report)
        ->status_is(200)
        ->json_schema_is('ValidationState')
        ->json_cmp_deeply(superhashof({
            device_id => 'TEST',
            status => 'pass',
            completed => re(qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3,9}Z$/),
        }));

    push @device_report_ids, $t->tx->res->json->{device_report_id};
    push @validation_state_ids, $t->tx->res->json->{id};

    cmp_deeply(
        $device->self_rs->latest_device_report->single,
        methods(
            id => $device_report_ids[-1],
            device_id => 'TEST',
            report => json(from_json($good_report)),
            invalid_report => undef,
            retain => bool(1),    # we keep the first report after an error result
        ),
        'stored the report in raw form',
    );

    is($device->related_resultset('device_reports')->count, 5, 'now five device_report rows exist');
    is($device->related_resultset('validation_states')->count, 3, 'three validation_state rows exist');
    is($t->app->db_validation_results->count, 1, 'the latest validation result is the same as the first');


	my $error_report = path('t/integration/resource/error-device-report.json')->slurp_utf8;
	$t->post_ok('/device/TEST', { 'Content-Type' => 'application/json' }, $error_report)
		->status_is(200)
		->json_schema_is('ValidationState')
		->json_is('/status', 'error');

    push @device_report_ids, $t->tx->res->json->{device_report_id};
    push @validation_state_ids, $t->tx->res->json->{id};

    is($device->related_resultset('device_reports')->count, 6, 'now six device_report rows exist');
    is($device->related_resultset('validation_states')->count, 4, 'now another validation_state row exists');
    is($t->app->db_validation_results->count, 2, 'now two validation results rows exist');

	$t->get_ok('/device/TEST')
		->status_is(200)
		->json_schema_is('DetailedDevice')
		->json_is('/health' => 'ERROR')
		->json_is('/latest_report_is_invalid' => JSON::PP::false);


	# return device to a good state
	$t->post_ok('/device/TEST', { 'Content-Type' => 'application/json' }, $good_report)
		->status_is(200)
		->json_schema_is('ValidationState')
		->json_is('/status', 'pass');

    push @device_report_ids, $t->tx->res->json->{device_report_id};
    push @validation_state_ids, $t->tx->res->json->{id};

    is($device->related_resultset('device_reports')->count, 7, 'now seven device_report rows exist');
    is($device->related_resultset('validation_states')->count, 5, 'now four validation_state rows exist');
    is($t->app->db_validation_results->count, 2, 'still just two validation result rows exist');


    cmp_deeply(
        [ $t->app->db_device_reports->order_by('created')->get_column('id')->all ],
        [ @device_report_ids[0,2,3,4,5,6,7] ],
        'kept all device reports except the passing report with a pass on both sides',
    );

    cmp_deeply(
        [ $t->app->db_validation_states->order_by('created')->get_column('id')->all ],
        [ @validation_state_ids[0,2,-3,-2,-1] ],
        'not every device report had an associated validation_state record',
    );


    subtest 'relocate a disk' => sub {
        # move one of the device's disks to a different device (and change another field so it
        # needs to be updated)...
        my $report_data = from_json($good_report);
        my $disk_serial = (keys $report_data->{disks}->%*)[0];
        $report_data->{disks}{$disk_serial}{size} += 100;    # ugh! make report not-unique
        my $new_device = $t->app->db_devices->create({
            id => 'ANOTHER_DEVICE',
            hardware_product_id => $device->hardware_product_id,
            state => 'UNKNOWN',
            health => 'UNKNOWN',
        });
        my $disk = $t->app->db_device_disks->search({ serial_number => $disk_serial })->single;
        $disk->update({ device_id => $new_device->id, vendor => 'King Zøg' });

        # then submit the report again and observe it moving back.
        $t->post_ok('/device/TEST', { 'Content-Type' => 'application/json' }, json => $report_data)
            ->status_is(200)
            ->json_schema_is('ValidationState')
            ->json_is('/status', 'pass');

        $disk->discard_changes;
        is($disk->device_id, $device->id, 'an existing disk is relocated to the latest device reporting it');
    };


    ok(
        $t->app->db_devices->search({ id => 'TEST' })->devices_without_location->exists,
        'device is unlocated',
    );
};

my $detailed_device;

subtest 'Single device' => sub {
	$t->get_ok('/device/nonexistent')
		->status_is(404)
		->json_is({ error => 'Not found' });

	$t->get_ok('/device/TEST')
		->status_is(200)
		->json_schema_is('DetailedDevice')
		->json_is('/health' => 'PASS')
		->json_is('/latest_report_is_invalid' => JSON::PP::false)
		->json_is('/latest_report/product_name' => 'Joyent-G1')
		->json_cmp_deeply('/disks/0/serial_number' => 'BTHC640405WM1P6PGN');

	$detailed_device = $t->tx->res->json;

	my $device_id = $detailed_device->{id};
	my @macs = map { $_->{mac} } $detailed_device->{nics}->@*;

	my $undetailed_device = {
		$detailed_device->%*,
		($t->app->db_device_locations->search({ device_id => 'TEST' })->hri->single // {})->%{qw(rack_id rack_unit_start)},
	};
	delete $undetailed_device->@{qw(latest_report_is_invalid latest_report invalid_report location nics disks)};

	subtest 'get by device attributes' => sub {

		$t->get_ok('/device?hostname=elfo')
			->status_is(200)
			->json_schema_is('Devices')
			->json_is('', [ $undetailed_device ], 'got device by hostname');

		$t->get_ok("/device?mac=$macs[0]")
			->status_is(200)
			->json_schema_is('Devices')
			->json_is('', [ $undetailed_device ], 'got device by mac');

		# device_nics->[2] has ipaddr' => '172.17.0.173'.
		$t->get_ok("/device?ipaddr=172.17.0.173")
			->status_is(200)
			->json_schema_is('Devices')
			->json_is('', [ $undetailed_device ], 'got device by ipaddr');
	};

	subtest 'mutate device attributes' => sub {
		$t->post_ok('/device/nonexistent/graduate')
			->status_is(404)
			->json_is({ error => 'Not found' });

		$t->post_ok('/device/TEST/graduate')
			->status_is(303)
			->location_is('/device/TEST');

		$t->post_ok('/device/TEST/triton_setup')
			->status_is(409)
			->json_like( '/error',
			qr/must be marked .+ before it can be .+ set up for Triton/ );

		$t->post_ok('/device/TEST/triton_reboot')
			->status_is(303)
			->location_is('/device/TEST');

		$t->post_ok('/device/TEST/triton_uuid')
			->status_is( 400, 'Request body required' );

		$t->post_ok('/device/TEST/triton_uuid', json => { triton_uuid => 'not a UUID' })
			->status_is(400)
			->json_like('/error', qr/String does not match/);

		$t->post_ok('/device/TEST/triton_uuid', json => { triton_uuid => $uuid->create_str() })
			->status_is(303)
			->location_is('/device/TEST');

		$t->post_ok('/device/TEST/triton_setup')
			->status_is(303)
			->location_is('/device/TEST');

		$t->post_ok('/device/TEST/asset_tag')
			->status_is( 400, 'Request body required' );

		$t->post_ok('/device/TEST/asset_tag', json => { asset_tag => 'asset tag' })
			->status_is(400)
			->json_like('/error', qr/String does not match/);

		$t->post_ok('/device/TEST/asset_tag', json => { asset_tag => 'asset_tag' })
			->status_is(303)
			->location_is('/device/TEST');

		$t->post_ok('/device/TEST/validated')
			->status_is(303)
			->location_is('/device/TEST');

		$t->post_ok('/device/TEST/validated')
			->status_is(204)
			->content_is('');

		$t->get_ok('/device/TEST')
			->status_is(200)
			->json_schema_is('DetailedDevice')
			->json_is('/id', 'TEST')
			->json_is('/health' => 'PASS')
			->json_is('/latest_report_is_invalid' => JSON::PP::false);
		$detailed_device = $t->tx->res->json;
	};

	my $rack_id = $t->load_fixture('legacy_datacenter_rack')->id;

	# device settings that check for 'admin' permission need the device to have a location
	$t->post_ok("/workspace/$global_ws_id/rack/$rack_id/layout",
			json => { TEST => 1, NEW_DEVICE => 3 })
		->status_is(200)
		->json_schema_is('WorkspaceRackLayoutUpdateResponse')
		->json_cmp_deeply({ updated => bag('TEST', 'NEW_DEVICE') });

    ok(
        !$t->app->db_devices->search({ id => 'TEST' })->devices_without_location->exists,
        'device is now located',
    );


	subtest 'Device settings' => sub {
		$t->get_ok('/device/TEST/settings')
			->status_is(200)
			->content_is('{}');

		$t->get_ok('/device/TEST/settings/foo')
			->status_is(404)
			->json_is({ error => 'No such setting \'foo\'' });

		$t->post_ok('/device/TEST/settings')
			->status_is( 400, 'Requires body' )
			->json_like( '/error', qr/required/ );

		$t->post_ok( '/device/TEST/settings', json => { foo => 'bar' } )
			->status_is(200)
			->content_is('');

		$t->get_ok('/device/TEST/settings')
			->status_is(200)
			->json_is( '/foo', 'bar', 'Setting was stored' );

		$t->get_ok('/device/TEST/settings/foo')
			->status_is(200)
			->json_is( '/foo', 'bar', 'Setting was stored' );

		$t->post_ok( '/device/TEST/settings/fizzle',
			json => { no_match => 'gibbet' } )
			->status_is( 400, 'Fail if parameter and key do not match' );

		$t->post_ok( '/device/TEST/settings/fizzle',
			json => { fizzle => 'gibbet' } )
			->status_is(200);

		$t->get_ok('/device/TEST/settings/fizzle')
			->status_is(200)
			->json_is( '/fizzle', 'gibbet' );

		$t->delete_ok('/device/TEST/settings/fizzle')
			->status_is(204)
			->content_is('');

		$t->get_ok('/device/TEST/settings/fizzle')
			->status_is(404)
			->json_is({ error => 'No such setting \'fizzle\'' });

		$t->delete_ok('/device/TEST/settings/fizzle')
			->status_is(404)
			->json_is({ error => 'No such setting \'fizzle\'' });

		$t->post_ok( '/device/TEST/settings',
			json => { 'tag.foo' => 'foo', 'tag.bar' => 'bar' } )->status_is(200);

		$t->post_ok( '/device/TEST/settings/tag.bar',
			json => { 'tag.bar' => 'newbar' } )->status_is(200);

		$t->get_ok('/device/TEST/settings/tag.bar')->status_is(200)
			->json_is( '/tag.bar', 'newbar', 'Setting was updated' );

		$t->delete_ok('/device/TEST/settings/tag.bar')->status_is(204)
			->content_is('');

		$t->get_ok('/device/TEST/settings/tag.bar')
			->status_is(404)
			->json_is({ error => 'No such setting \'tag.bar\'' });

		my $undetailed_device = {
			$detailed_device->%*,
			($t->app->db_device_locations->search({ device_id => 'TEST' })->hri->single // {})->%{qw(rack_id rack_unit_start)},
		};
		delete $undetailed_device->@{qw(latest_report_is_invalid latest_report invalid_report location nics disks)};

		$t->get_ok('/device?foo=bar')
			->status_is(200)
			->json_schema_is('Devices')
			->json_is('', [ $undetailed_device ], 'got device by arbitrary setting key');
	};

};

my $devices_data;

subtest 'Workspace devices' => sub {

	$t->get_ok("/workspace/$global_ws_id/device")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is('/0/id', 'TEST')
		->json_is('/1/id', 'NEW_DEVICE')
		->json_cmp_deeply([
			superhashof({
				id => 'TEST',
				graduated => re(qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3,9}Z$/),
				validated => re(qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3,9}Z$/),
				last_seen => re(qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3,9}Z$/),
				health => 'PASS',
			}),
			superhashof({
				id => 'NEW_DEVICE',
				graduated => undef,
				validated => undef,
				last_seen => undef,
				health => 'UNKNOWN',
			}),
		]);

	$devices_data = $t->tx->res->json;

	$t->get_ok("/workspace/$global_ws_id/device?graduated=f")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is('', [ $devices_data->[1] ]);

	$t->get_ok("/workspace/$global_ws_id/device?graduated=F")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is('', [ $devices_data->[1] ]);

	$t->get_ok("/workspace/$global_ws_id/device?graduated=t")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is('', [ $devices_data->[0] ]);

	$t->get_ok("/workspace/$global_ws_id/device?graduated=T")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is('', [ $devices_data->[0] ]);

	$t->get_ok("/workspace/$global_ws_id/device?validated=f")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is('', [ $devices_data->[1] ]);

	$t->get_ok("/workspace/$global_ws_id/device?validated=F")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is('', [ $devices_data->[1] ]);

	$t->get_ok("/workspace/$global_ws_id/device?validated=t")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is('', [ $devices_data->[0] ]);

	$t->get_ok("/workspace/$global_ws_id/device?validated=T")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is('', [ $devices_data->[0] ]);

	$t->get_ok("/workspace/$global_ws_id/device?health=fail")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is( '', [] );

	$t->get_ok("/workspace/$global_ws_id/device?health=FAIL")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is( '', [] );

	$t->get_ok("/workspace/$global_ws_id/device?health=pass")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is('', [ $devices_data->[0] ]);

	$t->get_ok("/workspace/$global_ws_id/device?health=PASS")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is('', [ $devices_data->[0] ]);

	$t->get_ok("/workspace/$global_ws_id/device?health=unknown")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is('', [ $devices_data->[1] ]);

	$t->get_ok("/workspace/$global_ws_id/device?health=pass&graduated=t")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is('', [ $devices_data->[0] ]);

	$t->get_ok("/workspace/$global_ws_id/device?health=pass&graduated=f")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is('', []);

	$t->get_ok("/workspace/$global_ws_id/device?ids_only=1")
		->status_is(200)
		->json_is(['TEST', 'NEW_DEVICE']);

	$t->get_ok("/workspace/$global_ws_id/device?ids_only=1&health=pass")
		->status_is(200)
		->json_is(['TEST']);

	$t->get_ok("/workspace/$global_ws_id/device?active=t")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is('', [ $devices_data->[0] ]);

	$t->get_ok("/workspace/$global_ws_id/device?active=t&graduated=t")
		->status_is(200)
		->json_schema_is('Devices')
		->json_is('', [ $devices_data->[0] ]);

	# /device/active redirects to /device so first make sure there is a redirect,
	# then follow it and verify the results
	subtest 'Redirect /workspace/:id/device/active' => sub {
		$t->get_ok("/workspace/$global_ws_id/device/active")
			->status_is(302)
			->location_is("/workspace/$global_ws_id/device?active=t");

		my $temp = $t->ua->max_redirects;
		$t->ua->max_redirects(1);

		$t->get_ok("/workspace/$global_ws_id/device/active")
			->status_is(200)
			->json_schema_is('Devices')
			->json_is('', [ $devices_data->[0] ]);

		$t->ua->max_redirects($temp);
	};
};

subtest 'Validations' => sub {
    my $validation_id = $t->app->db_validations->get_column('id')->single;

    my $validation_plan = $t->app->db_validation_plans->create({
        name => 'my_test_plan',
        description => 'another test plan',
    });
    my $validation_plan_id = $validation_plan->id;
    $validation_plan->find_or_create_related('validation_plan_members', { validation_id => $validation_id });

	subtest 'test validating a device' => sub {
		my $good_report = path('t/integration/resource/passing-device-report.json')->slurp_utf8;

		$t->post_ok("/device/TEST/validation/$validation_id", json => {})
			->status_is(400)
			->json_schema_is('Error');

		$t->post_ok("/device/TEST/validation/$validation_id",
				{ 'Content-Type' => 'application/json' }, $good_report)
			->status_is(200)
			->json_schema_is('ValidationResults')
			->json_cmp_deeply([ superhashof({
				id => undef,
				device_id => 'TEST',
			}) ]);

		my $validation_results = $t->tx->res->json;

		$t->post_ok("/device/TEST/validation_plan/$validation_plan_id", json => {})
			->status_is(400)
			->json_schema_is('Error');

		$t->post_ok("/device/TEST/validation_plan/$validation_plan_id",
				{ 'Content-Type' => 'application/json' }, $good_report)
			->status_is(200)
			->json_schema_is('ValidationResults')
			->json_is($validation_results);
	};


	my $device = $t->app->db_devices->find('TEST');
	my $device_report = $t->app->db_device_reports->rows(1)->order_by({ -desc => 'created' })->single;
	my $validation = $t->load_validation('Conch::Validation::BiosFirmwareVersion');

	# manually create a failing validation result... ew ew ew.
	# this uses the new validation plan, which is guaranteed to be different from the passing
	# valdiation that got recorded for this device via the report earlier.
	my $validation_state = $t->app->db_validation_states->create({
		device_id => 'TEST',
		validation_plan_id => $validation_plan_id,
		device_report_id => $device_report->id,
		status => 'fail',
		completed => \'NOW()',
		validation_state_members => [{
			validation_result => {
				device_id => 'TEST',
				hardware_product_id => $device->hardware_product_id,
				validation_id => $validation->id,
				message => 'faked failure',
				hint => 'boo',
				status => 'fail',
				category => 'test',
				result_order => 0,
			},
		}],
	});

	# record another, older, failing test using the same plan.
	$t->app->db_validation_states->create({
		device_id => 'TEST',
		validation_plan_id => $validation_plan_id,
		device_report_id => $device_report->id,
		status => 'fail',
		completed => '2001-01-01',
		validation_state_members => [{
			validation_result => {
				created => '2001-01-01',
				device_id => 'TEST',
				hardware_product_id => $device->hardware_product_id,
				validation_id => $validation->id,
				message => 'earlier failure',
				hint => 'boo',
				status => 'fail',
				category => 'test',
				result_order => 0,
			},
		}],
	});

	$t->get_ok('/device/TEST/validation_state')
		->status_is(200)
		->json_schema_is('ValidationStatesWithResults')
		->json_cmp_deeply(bag(
			{
				id => ignore,
				validation_plan_id => ignore,
				device_id => 'TEST',
				device_report_id => $device_report->id,
				completed => ignore,
				created => ignore,
				status => 'pass',	# we force-validated this device earlier
				results => [ ignore ],
			},
			{
				id => $validation_state->id,
				validation_plan_id => $validation_plan_id,
				device_id => 'TEST',
				device_report_id => $device_report->id,
				completed => ignore,
				created => ignore,
				status => 'fail',
				results => [ {
					id => ignore,
					device_id => 'TEST',
					hardware_product_id => $device->hardware_product_id,
					validation_id => $validation->id,
					component_id => undef,
					message => 'faked failure',
					hint => 'boo',
					status => 'fail',
					category => 'test',
					order => 0,
				} ],
			},
		));

	my $validation_states = $t->tx->res->json;

	$t->get_ok('/device/TEST/validation_state?status=pass')
		->status_is(200)
		->json_schema_is('ValidationStatesWithResults')
		->json_is([ grep { $_->{status} eq 'pass' } $validation_states->@* ]);

	$t->get_ok('/device/TEST/validation_state?status=fail')
		->status_is(200)
		->json_schema_is('ValidationStatesWithResults')
		->json_is([ grep { $_->{status} eq 'fail' } $validation_states->@* ]);

	$t->get_ok('/device/TEST/validation_state?status=error')
		->status_is(200)
		->json_schema_is('ValidationStatesWithResults')
		->json_cmp_deeply([
			{
				id => ignore,
				validation_plan_id => ignore,
				device_id => 'TEST',
				device_report_id => ignore,
				completed => ignore,
				created => ignore,
				status => 'error',
				results => [ {
					id => ignore,
					device_id => 'TEST',
					hardware_product_id => $device->hardware_product_id,
					validation_id => ignore,
					component_id => undef,
					message => 'Missing \'product_name\' property',
					hint => ignore,
					status => 'error',
					category => 'BIOS',
					order => 0,
				} ],
			},
		]);

	$t->get_ok('/device/TEST/validation_state?status=pass,fail')
		->status_is(200)
		->json_schema_is('ValidationStatesWithResults')
		->json_is($validation_states);

	$t->get_ok('/device/TEST/validation_state?status=pass,bar')
		->status_is(400)
		->json_is({ error => "'status' query parameter must be any of 'pass', 'fail', or 'error'." });
};

subtest 'Device location' => sub {
	$t->post_ok('/device/TEST/location')
		->status_is(400, 'requires body')
		->json_like('/error', qr/Expected object/);

	my $rack_id = $t->load_fixture('legacy_datacenter_rack')->id;

	$t->post_ok('/device/TEST/location', json => { rack_id => $rack_id, rack_unit => 42 })
		->status_is(409)
		->json_is({ error => "slot 42 does not exist in the layout for rack $rack_id" });

	$t->post_ok('/device/TEST/location', json => { rack_id => $rack_id, rack_unit => 3 })
		->status_is(303)
		->location_is('/device/TEST/location');

	$t->delete_ok('/device/TEST/location')
		->status_is(204, 'can delete device location');

	$t->post_ok('/device/TEST/location', json => { rack_id => $rack_id, rack_unit => 3 })
		->status_is(303, 'add it back');
};

subtest 'Log out' => sub {
	$t->post_ok("/logout")->status_is(204);
	$t->get_ok("/workspace")->status_is(401);
};

subtest 'Permissions' => sub {
	my $ro_name = 'wat';
	my $ro_email = 'readonly@wat.wat';
	my $ro_pass = 'password';

	my $rack_id = $t->load_fixture('legacy_datacenter_rack')->id;

	subtest 'Read-only' => sub {
		my $ro_user = $t->app->db_user_accounts->create({
			name => $ro_name,
			email => $ro_email,
			password => $ro_pass,
			user_workspace_roles => [{
				workspace_id => $global_ws_id,
				role => 'ro',
			}],
		});

		$t->authenticate(user => $ro_email, password => $ro_pass);

		$t->get_ok('/workspace')
			->status_is(200)
			->json_schema_is('WorkspacesAndRoles')
			->json_is( '/0/name', 'GLOBAL' );

		subtest "Can't create a subworkspace" => sub {
			$t->post_ok(
				"/workspace/$global_ws_id/child" => json => {
					name        => "test",
					description => "also test",
				}
			)->status_is(403)
			->json_is({ error => 'Forbidden' });
		};

		subtest "Can't add a rack" => sub {
			$t->post_ok( "/workspace/$global_ws_id/rack", json => { id => $rack_id } )
				->status_is(403)
				->json_is({ error => 'Forbidden' });
		};

		subtest "Can't set a rack layout" => sub {
			$t->post_ok(
				"/workspace/$global_ws_id/rack/$rack_id/layout",
				json => {
					TEST => 1
				}
			)->status_is(403)
			->json_is({ error => 'Forbidden' });
		};

		subtest "Can't add a user to workspace" => sub {
			$t->post_ok(
				"/workspace/$global_ws_id/user",
				json => {
					user => 'another@wat.wat',
					role => 'ro',
				}
			)->status_is(403)
			->json_is({ error => 'Forbidden' });
		};

		subtest "Can't get a relay list" => sub {
			$t->get_ok("/relay")->status_is(403);
		};

		$t->get_ok("/workspace/$global_ws_id/user")
			->status_is(200, 'get list of users for this workspace')
			->json_schema_is('WorkspaceUsers')
			->json_cmp_deeply(bag(
				{
					id => ignore,
					name => $t->CONCH_USER,
					email => $t->CONCH_EMAIL,
					role => 'admin',
				},
				{
					id => $ro_user->id,
					name => $ro_name,
					email => $ro_email,
					role => 'ro',
				},
			));

		subtest 'device settings' => sub {
			$t->post_ok('/device/TEST/settings', json => { name => 'new value' })
				->status_is(403)
				->json_is({ error => 'Forbidden' });
			$t->post_ok('/device/TEST/settings/foo', json => { foo => 'new_value' })
				->status_is(403)
				->json_is({ error => 'Forbidden' });
			$t->delete_ok('/device/TEST/settings/foo')
				->status_is(403)
				->json_is({ error => 'Forbidden' });
		};

		$t->post_ok("/logout")->status_is(204);
	};

	subtest "Read-write" => sub {
		my $name = 'integrator';
		my $email = 'integrator@wat.wat';
		my $pass = 'password';

		my $user = $t->app->db_user_accounts->create({
			name => $name,
			email => $email,
			password => $pass,
			user_workspace_roles => [{
				workspace_id => $global_ws_id,
				role => 'rw',
			}],
		});

		$t->authenticate(user => $email, password => $pass);

		$t->get_ok('/workspace')
			->status_is(200)
			->json_schema_is('WorkspacesAndRoles')
			->json_is( '/0/name', 'GLOBAL' );

		subtest "Can't create a subworkspace" => sub {
			$t->post_ok(
				"/workspace/$global_ws_id/child" => json => {
					name        => "test",
					description => "also test",
				}
			)->status_is(403)
			->json_is({ error => 'Forbidden' });
		};

		subtest "Can't add a user to workspace" => sub {
			$t->post_ok(
				"/workspace/$global_ws_id/user",
				json => {
					user => 'another@wat.wat',
					role => 'ro',
				}
			)->status_is(403)
			->json_is({ error => 'Forbidden' });
		};

		subtest "Can't get a relay list" => sub {
			$t->get_ok("/relay")->status_is(403);
		};

		$t->get_ok("/workspace/$global_ws_id/user")
			->status_is(200, 'get list of users for this workspace')
			->json_schema_is('WorkspaceUsers')
			->json_cmp_deeply(bag(
				{
					id => ignore,
					name => $t->CONCH_USER,
					email => $t->CONCH_EMAIL,
					role => 'admin',
				},
				{
					id => ignore,
					name => $ro_name,
					email => $ro_email,
					role => 'ro',
				},
				{
					id => $user->id,
					name => $name,
					email => $email,
					role => 'rw',
				},
			));

		subtest 'device settings' => sub {
			$t->post_ok('/device/TEST/settings', json => { newkey => 'new value' })
				->status_is(200, 'writing new key only requires rw');
			$t->post_ok('/device/TEST/settings/foo', json => { foo => 'new_value' })
				->status_is(403)
				->json_is({ error => 'insufficient permissions' });
			$t->delete_ok('/device/TEST/settings/foo')
				->status_is(403)
				->json_is({ error => 'insufficient permissions' });

			$t->post_ok('/device/TEST/settings', json => { 'foo' => 'foo', 'tag.bar' => 'bar' })
				->status_is(403)
				->json_is({ error => 'insufficient permissions' });
			$t->post_ok('/device/TEST/settings', json => { 'tag.foo' => 'foo', 'tag.bar' => 'bar' })
				->status_is(200);

			$t->post_ok('/device/TEST/settings/tag.bar',
				json => { 'tag.bar' => 'newbar' } )->status_is(200);
			$t->get_ok('/device/TEST/settings/tag.bar')->status_is(200)
				->json_is('/tag.bar', 'newbar', 'Setting was updated');
			$t->delete_ok('/device/TEST/settings/tag.bar')->status_is(204)
				->content_is('');
			$t->get_ok('/device/TEST/settings/tag.bar')->status_is(404)
				->json_is({ error => 'No such setting \'tag.bar\'' });
		};

		$t->post_ok("/logout")->status_is(204);
	};
};

done_testing();
