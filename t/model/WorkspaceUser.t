use Mojo::Base -strict;
use Test::More;
use Test::ConchTmpDB qw(mk_tmp_db);
use Conch::Pg;

use_ok("Conch::Model::Workspace");
use_ok("Conch::Model::WorkspaceUser");

my $pgtmp = mk_tmp_db();
$pgtmp or die;
my $pg    = Conch::Pg->new( $pgtmp->uri );
my $schema = Test::ConchTmpDB->schema($pgtmp);

my $new_user = $schema->resultset('UserAccount')->create({
	name => 'foo',
	email => 'foo@bar.com',
	password => 'password',
});

my $ws_model = new_ok( "Conch::Model::Workspace" );
my $global_ws = $ws_model->lookup_by_name('GLOBAL');

$ws_model->add_user_to_workspace( $new_user->id, $global_ws->id, 'ro' );

new_ok('Conch::Model::WorkspaceUser');
my $ws_user_model = new_ok( "Conch::Model::WorkspaceUser" );

subtest "Get list of workspace users" => sub {
	my $workspace_users = $ws_user_model->workspace_users( $global_ws->id );
	isa_ok( $workspace_users, 'ARRAY' );
	is( scalar @$workspace_users, 2 );
	isa_ok( $workspace_users->[0], 'Conch::Class::WorkspaceUser' );
};

done_testing();
