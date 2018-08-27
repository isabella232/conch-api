package Conch::Route::Device;
use Mojo::Base -strict;

use Exporter 'import';
our @EXPORT_OK = qw(device_routes);

=pod

=head1 NAME

Conch::Route::Device

=head1 METHODS

=head2 device_routes

Sets up routes for /device:

    GET     /device/role
    POST    /device/role
    GET     /device/role/:device_role_id
    POST    /device/role/:device_role_id
    DELETE  /device/role/:device_role_id
    POST    /device/role/:device_role_id/add_service
    POST    /device/role/:device_role_id/remove_service

    GET     /device/service
    POST    /device/service
    GET     /device/service/:device_service_id
    POST    /device/service/:device_service_id
    DELETE  /device/service/:device_service_id

    GET     /device/:device_id
    POST    /device/:device_id
    POST    /device/:device_id/graduate
    POST    /device/:device_id/triton_setup
    POST    /device/:device_id/triton_uuid
    POST    /device/:device_id/triton_reboot
    POST    /device/:device_id/asset_tag
    POST    /device/:device_id/validated
    GET     /device/:device_id/location
    POST    /device/:device_id/location
    DELETE  /device/:device_id/location
    GET     /device/:device_id/settings
    POST    /device/:device_id/settings
    GET     /device/:device_id/settings/#key
    POST    /device/:device_id/settings/#key
    DELETE  /device/:device_id/settings/#key
    POST    /device/:device_id/validation/#validation_id
    POST    /device/:device_id/validation_plan/#validation_plan_id
    GET     /device/:device_id/validation_state
    GET     /device/:device_id/validation_result
    GET     /device/:device_id/role
    POST    /device/:device_id/role

=cut

sub device_routes {
    my $device = shift; # secured, under /device

    {
        my $dr = $device->any('/role');

        # GET /device/role
        $dr->get('/')->to('device_roles#get_all');
        # POST /device/role
        $dr->post('/')->to('device_roles#create');

        {
            my $dri = $dr->any('/:device_role_id');

            # GET /device/role/:device_role_id
            $dri->get('/')->to('device_roles#get_one');
            # POST /device/role/:device_role_id
            $dri->post('/')->to('device_roles#update');
            # DELETE /device/role/:device_role_id
            $dri->delete('/')->to('device_roles#delete');
            # POST /device/role/:device_role_id/add_service
            $dri->post('/add_service')->to('device_roles#add_service');
            # POST /device/role/:device_role_id/remove_service
            $dri->post('/remove_service')->to('device_roles#remove_service');
        }
    }

    {
        my $drs = $device->any('/service');

        # GET /device/service
        $drs->get('/')->to('device_services#get_all');
        # POST /device/service
        $drs->post('/')->to('device_services#create');

        {
            # chainable action that extracts and looks up id (of various types) from the path
            my $drsi = $drs->under('/:device_service_id')->to('device_services#find_device_service');

            # GET /device/service/:device_service_id
            $drsi->get('/')->to('device_services#get_one');
            # POST /device/service/:device_service_id
            $drsi->post('/')->to('device_services#update');
            # DELETE /device/service/:device_service_id
            $drsi->delete('/')->to('device_services#delete');
        }
    }

    # routes namespaced for a specific device
    {
        # POST /device/:device_id
        $device->post('/:device_id')->to('device_report#process');

        # chainable action that extracts and looks up device_service_id from the path
        my $with_device = $device->under('/:device_id')->to('device#find_device');

        # GET /device/:device_id
        $with_device->get('/')->to('device#get');

        # POST /device/:device_id/graduate
        $with_device->post('/graduate')->to('device#graduate');
        # POST /device/:device_id/triton_setup
        $with_device->post('/triton_setup')->to('device#set_triton_setup');
        # POST /device/:device_id/triton_uuid
        $with_device->post('/triton_uuid')->to('device#set_triton_uuid');
        # POST /device/:device_id/triton_reboot
        $with_device->post('/triton_reboot')->to('device#set_triton_reboot');
        # POST /device/:device_id/asset_tag
        $with_device->post('/asset_tag')->to('device#set_asset_tag');
        # POST /device/:device_id/validated
        $with_device->post('/validated')->to('device#set_validated');

        {
            my $with_device_location = $with_device->any('/location');
            # GET /device/:device_id/location
            $with_device_location->get('/')->to('device_location#get');
            # POST /device/:device_id/location
            $with_device_location->post('/')->to('device_location#set');
            # DELETE /device/:device_id/location
            $with_device_location->delete('/')->to('device_location#delete');
        }

        {
            my $with_device_settings = $with_device->any('/settings');
            # GET /device/:device_id/settings
            $with_device_settings->get('/')->to('device_settings#get_all');
            # POST /device/:device_id/settings
            $with_device_settings->post('/')->to('device_settings#set_all');

            my $with_device_settings_with_key = $with_device_settings->any('/#key');
            # GET /device/:device_id/settings/#key
            $with_device_settings_with_key->get('/')->to('device_settings#get_single');
            # POST /device/:device_id/settings/#key
            $with_device_settings_with_key->post('/')->to('device_settings#set_single');
            # DELETE /device/:device_id/settings/#key
            $with_device_settings_with_key->delete('/')->to('device_settings#delete_single');
        }

        # POST /device/:device_id/validation/#validation_id
        $with_device->post('/validation/#validation_id')->to('device_validation#validate');
        # POST /device/:device_id/validation_plan/#validation_plan_id
        $with_device->post('/validation_plan/#validation_plan_id')->to('device_validation#run_validation_plan');
        # GET /device/:device_id/validation_state
        $with_device->get('/validation_state')->to('device_validation#list_validation_states');
        # GET /device/:device_id/validation_result
        $with_device->get('/validation_result')->to('device_validation#list_validation_results');

        # GET /device/:device_id/role
        $with_device->get('/role')->to('device#get_role');
        # POST /device/:device_id/role
        $with_device->post('/role')->to('device#set_role');
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
# vim: set ts=4 sts=4 sw=4 et :
