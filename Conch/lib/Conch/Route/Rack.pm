package Conch::Route::Rack;

use strict;

use Dancer2 appname => 'Conch';
use Dancer2::Plugin::Auth::Tiny;
use Dancer2::Plugin::DBIC;
use Dancer2::Plugin::LogReport;
use Dancer2::Plugin::REST;
use Hash::MultiValue;
use Conch::Control::Rack;

use Data::Printer;

set serializer => 'JSON';

# Return all racks an integrator user has access to
# Admins currently don't have access to endpoint and they get a 401.
# TODO: If we want to add admin access, what should this endpoint return? All
# devices across all DCs?
get '/rack' => needs integrator => sub {
  my $user_name = session->read('integrator');
  debug "Collecting racks for $user_name"; 
  my $racks;
  process sub { $racks = racks_for_user(schema, $user_name); };
  status_200({racks => ($racks || []) });
};

# Returns defined rack roles.
get '/rack/role' => needs integrator => sub {
  my $roles;
  process sub { $roles = rack_roles(schema); };
  status_200({roles => ($roles || []) });
};

# Returns a rack with layout.
get '/rack/:uuid' => needs integrator => sub {
  my $user_name = session->read('integrator');

  my $uuid = param 'uuid';

  # Verify this rack is assigned to the user.
  my $user_racks;
  process sub { $user_racks = racks_for_user(schema, $user_name); };

  # XXX This is terrible -- bdha
  my $authorized = 0;
  foreach my $az (keys %{$user_racks}) {
    if (defined $user_racks->{$az}{$uuid}) {
      $authorized = 1;
    }
  }

  unless ($authorized) {
    warning "$user_name not allowed to view rack $uuid or rack does not exist";
    return status_401('unauthorized');
  }

  status_200({rack => $uuid}); 

};

# TODO
# Populate the device_location table.
# post '/rack/:uuid' => needs integrator => sub {
#};

1;
