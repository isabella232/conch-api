package Conch::Controller::JSONSchema;

use Mojo::Base 'Mojolicious::Controller', -signatures;

=pod

=head1 NAME

Conch::Controller::JSONSchema

=head1 METHODS

=head2 get

Get a query parameters, request, response, common or device_report JSON Schema (from
F<query_params.yaml>, F<request.yaml>, F<response.yaml>, F<common.yaml>, or F<device_report.yaml>,
respectively). Bundles all the referenced definitions together in the returned body response.

=cut

sub get ($c) {
    # set Last-Modified header; return 304 if If-Modified-Since is recent enough.
    # For now, just use the server start time. We could do something more sophisticated with
    # the timestamps on the schema file(s), but this is fiddly and involves following all $refs
    # to see what files they came from.
    return $c->status(304) if $c->is_fresh(last_modified => $c->startup_time->epoch);

    my $type = $c->stash('json_schema_type');
    my $name = $c->stash('json_schema_name');

    my $validator = $type eq 'query_params' || $type eq 'request' || $type eq 'response'
        ? $c->${\('get_'.$type.'_validator')}
        : do {  # ugh. this is going away soon.
            my $jv = JSON::Validator->new;
            $jv->formats->{uri} = \&Conch::Plugin::JSONValidator::_check_uri;
            $jv->load_and_validate_schema(
                'json-schema/'.$type.'.yaml',
                { schema => 'http://json-schema.org/draft-07/schema#' });
            $jv;
        };

    my $schema = _extract_schema_definition($validator, $name);
    if (not $schema) {
        $c->log->warn('Could not find '.$type.' schema '.$name);
        return $c->status(404);
    }

    # the canonical location of this document -- which should be the same URL used to get here
    $schema->{'$id'} = $c->url_for('/json_schema/'.$type.'/'.$name)->to_abs;

    $c->res->headers->content_type('application/schema+json');
    return $c->status(200, $schema);
}

=head2 _extract_schema_definition

Given a L<JSON::Validator> object containing a schema definition, extract the requested portion
out of the "definitions" section, including any named references, and add some standard
headers.

TODO: this (plus addition of the header fields) could mostly be replaced with just:

    my $new_defs = $jv->bundle({
        schema => $jv->get('/definitions/'.$name),
        ref_key => 'definitions',
    });

..except circular refs are not handled there, and the definition renaming leaks local path info.

=cut

sub _extract_schema_definition ($validator, $schema_name) {
    my $top_schema = $validator->schema->get('/definitions/'.$schema_name);
    return if not $top_schema;

    my %refs;
    my %source;
    my $definitions;
    my @topics = ([{ schema => $top_schema }, my $target = {}]);
    my $cloner = sub ($from) {
        if (ref $from eq 'HASH' and my $tied = tied %$from) {
            # this is a hashref which quacks like { '$ref' => $target }
            my ($location, $path) = split /#/, $tied->fqn, 2;
            (my $name = $path) =~ s!^/definitions/!!;

            if (not $refs{$tied->fqn}++) {
                # TODO: use a heuristic to find a new name for the conflicting definition
                if ($name ne $schema_name and exists $source{$name}) {
                    die 'namespace collision: '.$tied->fqn.' but already have a /definitions/'.$name
                        .' from '.$source{$name}->fqn;
                }

                $source{$name} = $tied;
                push @topics, [$tied->schema, $definitions->{$name} = {}];
            }

            ++$refs{'/traversed_definitions/'.$name};
            tie my %ref, 'JSON::Validator::Ref', $tied->schema, '#/definitions/'.$name;
            return \%ref;
        }

        my $to = ref $from eq 'ARRAY' ? [] : ref $from eq 'HASH' ? {} : $from;
        push @topics, [$from, $to] if ref $from;
        return $to;
    };

    while (@topics) {
        my ($from, $to) = @{shift @topics};
        if (ref $from eq 'ARRAY') {
            push @$to, $cloner->($_) foreach @$from;
        }
        elsif (ref $from eq 'HASH') {
            $to->{$_} = $cloner->($from->{$_}) foreach keys %$from;
        }
    }

    $target = $target->{schema};

    # cannot return a $ref at the top level (sibling keys disallowed) - inline the $ref.
    while (my $tied = tied %$target) {
        (my $name = $tied->fqn) =~ s!^#/definitions/!!;
        $target = $definitions->{$name};
        delete $definitions->{$name} if $refs{'/traversed_definitions/'.$name} == 1;
    }

    return {
        '$schema' => $validator->get('/$schema') || 'http://json-schema.org/draft-07/schema#',
        # no $id - we have no idea of this document's canonical location
        keys $definitions->%* ? ( definitions => $definitions ) : (),
        $target->%*,
    };
}

1;
__END__

=pod

=head1 LICENSING

Copyright Joyent, Inc.

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at L<https://www.mozilla.org/en-US/MPL/2.0/>.

=cut

# vim: set ts=4 sts=4 sw=4 et :
