package Test::MojoSchema;
use Mojo::Base 'Test::Mojo';

has 'validator';

# Adds a method 'json_schema_is` to validate the JSON response of
# the most recent request. If given a string, looks up the schema in
# #/definitions in the JSON Schema spec to validate. If given a hash, uses
# the hash as the schema to validate.
#
# Why subclass Test::Mojo rather than just defining a subroutine? This keeps
# the nice fluid interface of Test::Mojo, and Test::Mojo already has the
# machinery in place to show the line number /where the test is invoked/,
# rather than where it's defined.
sub json_schema_is {
	my ( $self, $schema ) = @_;

	my @errors;
	return $self->_test( 'fail', 'No request has been made' ) unless $self->tx;
	my $json = $self->tx->res->json;
	return $self->_test( 'fail', 'No JSON in response' ) unless $json;

	if ( ref $schema eq 'HASH' ) {
		@errors = $self->validator->validate( $json, $schema );
	}
	else {
		my $component_schema = $self->validator->get("/definitions/$schema");
		return $self->_test( 'fail',
			"Component schema '$schema' is not defined in JSON schema " )
			unless $component_schema;
		@errors = $self->validator->validate( $json, $component_schema );
	}

	my $error_count = @errors;
	my $req         = $self->tx->req->method . ' ' . $self->tx->req->url->path;
	return $self->_test( 'ok', !$error_count,
		'JSON response has no schema validation errors' )->or(
		sub {
			Test::More::diag( $error_count
					. " Error(s) occurred when validating $req with schema "
					. "$schema':\n\t"
					. join( "\n\t", @errors ) );
		}
		);
};

1;
