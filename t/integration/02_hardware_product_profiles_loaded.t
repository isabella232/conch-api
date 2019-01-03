use Mojo::Base -strict;
use Test::More;
use Data::UUID;
use Path::Tiny;
use Test::Warnings;
use Test::Conch;
use Test::Deep;

my $uuid = Data::UUID->new;

my $t = Test::Conch->new;
$t->load_fixture('conch_user_global_workspace', '00-hardware', '01-hardware-profiles');
$t->load_validation_plans([{
    name        => 'Conch v1 Legacy Plan: Server',
    description => 'Test Plan',
    validations => [ 'Conch::Validation::DeviceProductName' ],
}]);

# delete all zpools from hardware product profiles
$t->app->db_hardware_product_profiles->update({ zpool_id => undef });

$t->get_ok("/ping")->status_is(200)->json_is( '/status' => 'ok' );
$t->get_ok("/version")->status_is(200);

$t->post_ok(
	"/login" => json => {
		user     => 'conch@conch.joyent.us',
		password => 'conch'
	}
)->status_is(200);
BAIL_OUT("Login failed") if $t->tx->res->code != 200;

isa_ok( $t->tx->res->cookie('conch'), 'Mojo::Cookie::Response' );

$t->get_ok('/workspace')->status_is(200)->json_is( '/0/name', 'GLOBAL' );

my $id = $t->tx->res->json->[0]{id};
BAIL_OUT("No workspace ID") unless $id;

subtest 'Register relay' => sub {
	$t->post_ok(
		'/relay/deadbeef/register',
		json => {
			serial   => 'deadbeef',
			version  => '0.0.1',
			ipaddr   => '127.0.0.1',
			ssh_port => '22',
			alias    => 'test relay'
		}
	)->status_is(204);
};

subtest 'Relay List' => sub {
	$t->get_ok('/relay')->status_is(200);
	$t->json_is('/0/id' => 'deadbeef');
};

subtest 'Device Report' => sub {
	my $report = path('t/integration/resource/passing-device-report.json')->slurp_utf8;
	$t->post_ok( '/device/TEST', { 'Content-Type' => 'application/json' }, $report )
		->status_is(200, 'Device reports process despite hardware profiles not having a zpool profile')
		->json_schema_is('ValidationState')
		->json_is( '/status', 'pass' );
};

subtest 'Hardware Product' => sub {
	$t->get_ok('/hardware_product')
		->status_is(200)
		->json_schema_is('HardwareProducts')
		->json_cmp_deeply('',
			bag(
				superhashof({
					name => '2-ssds-1-cpu',
					hardware_product_profile => superhashof({
						zpool_profile => undef,
					}),
				}),
				superhashof({
					name => '65-ssds-2-cpu',
					hardware_product_profile => superhashof({
						zpool_profile => undef,
					}),
				}),
				superhashof({
					name => 'Switch',
					hardware_product_profile => superhashof({
						zpool_profile => undef,
					}),
				}),
			),
		);

	for my $hardware_product ($t->tx->res->json->@*) {
		$t->get_ok("/hardware_product/" . $hardware_product->{id} )
			->status_is(200)
			->json_schema_is('HardwareProduct')
			->json_is('', $hardware_product);
	}
};

done_testing();
