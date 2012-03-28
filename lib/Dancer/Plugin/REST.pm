package Dancer::Plugin::REST;

use strict;
use warnings;

use Carp 'croak';
use Dancer ':syntax';
use Dancer::Plugin;

our $AUTHORITY = 'SUKRIA';
our $VERSION   = '0.07';
our %routes;

use base 'Exporter';

my $content_types = {
    json => 'application/json',
    yml  => 'text/x-yaml',
    xml  => 'application/xml',
};

my $inflect;

sub import {
    my ($class, @args) = @_;
    my @final_args;

    for my $arg ( @args ) {
        if ($arg eq ':inflect') {
            require Lingua::EN::Inflect::Number;
            $inflect = 1;
        }
        else {
            push @final_args, $arg;
        }
    }

    $class->export_to_level(1, $class, @final_args);
}


# thanks leont
sub _function_exists {
    no strict 'refs';
    my $funcname = shift;
    return \&{$funcname} if defined &{$funcname};
    return;
}

register prepare_serializer_for_format => sub {
    my $conf        = plugin_setting;
    my $serializers = (
        ($conf && exists $conf->{serializers})
        ? $conf->{serializers}
        : { 'json' => 'JSON',
            'yml'  => 'YAML',
            'xml'  => 'XML',
            'dump' => 'Dumper',
        }
    );

    hook 'before' => sub {
        my $format = params->{'format'};
        return unless defined $format;

        my $serializer = $serializers->{$format};
        unless (defined $serializer) {
            return halt(
                Dancer::Error->new(
                    code    => 404,
                    message => "unsupported format requested: " . $format
                )
            );
        }

        set serializer => $serializer;
        my $ct = $content_types->{$format} || setting('content_type');
        content_type $ct;
    };
};

register resource => sub {
    my ($resource, %triggers) = @_;

    # if this resource is a nested child resource, manage the prefix
    my $old_prefix = prefix || '';
    if ($triggers{parent} and $routes{$triggers{parent}}) {
        prefix $routes{$triggers{parent}};
    }

    # we only want one of these, read takes precedence
    $triggers{read} = $triggers{get} if ! $triggers{read};

    for my $func (qw/load load_all/) {
        $triggers{$func} = sub { } if ref $triggers{$func} ne 'CODE';
    }

    my $params = $triggers{params} || ['id'];

    my $singular = $resource;
    if ($inflect) {
        eval { $singular = Lingua::EN::Inflect::Number::to_S($resource); };
        if ($@) {
            die "Unable to Inflect resource: $@";
        }
        $params = ["${singular}_id"];
    }

    my $param_string = join '/', map { ":$_" } @$params;

    my ($package) = caller;

    for my $verb (qw/create get read update delete index/) {
        # if get_foo is defined, use that.
        if ($inflect) {
            if ($verb eq 'index') {
                if (my $func = _function_exists("${package}::${verb}_${resource}")) {
                    $triggers{$verb} ||= sub {
                        $func->($triggers{load_all}->())
                    };
               }
            }
            else {
                if (my $func = _function_exists("${package}::${verb}_${singular}")) {
                    $triggers{$verb} ||= sub {
                        $func->($triggers{load}->());
                    };
                }
            }
        }

        # if we've gotten this far, no route exists. use a default
        $triggers{$verb} ||= sub { status_method_not_allowed('Method not allowed.'); };
    }

    my %verb2action = (
        read   => \&get,
        create => \&post,
        update => \&put,
        delete => \&del
    );

    for my $member (@{$triggers{member}}) {

        for my $verb (qw/create read update delete/) {
            # try and find the method via caller package
            my $wrap;
            if (my $func = _function_exists("${package}::${verb}_${singular}_${member}")) {
                $wrap = sub { $func->($triggers{load}->()); };
            }
            else {
                # default to 405 method not allowed
                $wrap = sub { status_method_not_allowed('Method not allowed.'); };
            }

            # register it
            $verb2action{$verb}->("/${resource}/${param_string}/${member}", $wrap);
            $verb2action{$verb}->("/${resource}/${param_string}/${member}.:format", $wrap);
        }
    }

    for my $member (@{$triggers{collection}}) {

        for my $verb (qw/create read update delete/) {
            # try and find the method via caller package
            my $wrap;
            if (my $func = _function_exists("${package}::${verb}_${resource}_${member}")) {
                $wrap = sub { $func->($triggers{load_all}->()); };
            }
            else {
                # default to 405 method not allowed
                $wrap = sub { status_method_not_allowed('Method not allowed.'); };
            }

            # register it
            $verb2action{$verb}->("/${resource}/${member}", $wrap);
            $verb2action{$verb}->("/${resource}/${member}.:format", $wrap);
        }
    }

    get "/${resource}.:format" => $triggers{index};
    get "/${resource}"         => $triggers{index};

    post "/${resource}.:format" => $triggers{create};
    post "/${resource}"         => $triggers{create};

    get "/${resource}/${param_string}.:format" => $triggers{read};
    get "/${resource}/${param_string}"         => $triggers{read};

    put "/${resource}/${param_string}.:format" => $triggers{update};
    put "/${resource}/${param_string}"         => $triggers{update};

    del "/${resource}/${param_string}.:format" => $triggers{delete};
    del "/${resource}/${param_string}"         => $triggers{delete};

    # save every defined resource if it is referred as a parent in a nested child resource
    $routes{$resource} = "${old_prefix}/${resource}/${param_string}";

    # restore existing prefix if saved
    prefix $old_prefix if $old_prefix;
};

register send_entity => sub {
    my ($entity, $http_code) = @_;

    $http_code ||= 200;

    status($http_code);
    $entity;
};

my %http_codes = (

    # 1xx
    100 => 'Continue',
    101 => 'Switching Protocols',
    102 => 'Processing',

    # 2xx
    200 => 'OK',
    201 => 'Created',
    202 => 'Accepted',
    203 => 'Non-Authoritative Information',
    204 => 'No Content',
    205 => 'Reset Content',
    206 => 'Partial Content',
    207 => 'Multi-Status',
    210 => 'Content Different',

    # 3xx
    300 => 'Multiple Choices',
    301 => 'Moved Permanently',
    302 => 'Found',
    303 => 'See Other',
    304 => 'Not Modified',
    305 => 'Use Proxy',
    307 => 'Temporary Redirect',
    310 => 'Too many Redirect',

    # 4xx
    400 => 'Bad Request',
    401 => 'Unauthorized',
    402 => 'Payment Required',
    403 => 'Forbidden',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    406 => 'Not Acceptable',
    407 => 'Proxy Authentication Required',
    408 => 'Request Time-out',
    409 => 'Conflict',
    410 => 'Gone',
    411 => 'Length Required',
    412 => 'Precondition Failed',
    413 => 'Request Entity Too Large',
    414 => 'Request-URI Too Long',
    415 => 'Unsupported Media Type',
    416 => 'Requested range unsatisfiable',
    417 => 'Expectation failed',
    418 => 'Teapot',
    422 => 'Unprocessable entity',
    423 => 'Locked',
    424 => 'Method failure',
    425 => 'Unordered Collection',
    426 => 'Upgrade Required',
    449 => 'Retry With',
    450 => 'Parental Controls',

    # 5xx
    500 => 'Internal Server Error',
    501 => 'Not Implemented',
    502 => 'Bad Gateway',
    503 => 'Service Unavailable',
    504 => 'Gateway Time-out',
    505 => 'HTTP Version not supported',
    507 => 'Insufficient storage',
    509 => 'Bandwidth Limit Exceeded',
);

for my $code (keys %http_codes) {
    my $helper_name = lc($http_codes{$code});
    $helper_name =~ s/[^\w]+/_/gms;
    $helper_name = "status_${helper_name}";

    register $helper_name => sub {
        if ($code >= 400) {
            send_entity({error => $_[0]}, $code);
        }
        else {
            send_entity($_[0], $code);
        }
    };
}

register_plugin;
1;
__END__

=pod

=head1 NAME

Dancer::Plugin::REST - A plugin for writing RESTful apps with Dancer

=head1 SYNOPSYS

    package MyWebService;

    use Dancer;
    use Dancer::Plugin::REST;

    prepare_serializer_for_format;

    get '/user/:id.:format' => sub {
        User->find(params->{id});
    };

    # curl http://mywebservice/user/42.json
    { "id": 42, "name": "John Foo", email: "john.foo@example.com"}

    # curl http://mywebservice/user/42.yml
    --
    id: 42
    name: "John Foo"
    email: "john.foo@example.com"

=head1 DESCRIPTION

This plugin helps you write a RESTful webservice with Dancer.

=head1 KEYWORDS

=head2 prepare_serializer_for_format

When this pragma is used, a before filter is set by the plugin to automatically
change the serializer when a format is detected in the URI.

That means that each route you define with a B<:format> token will trigger a
serializer definition, if the format is known.

This lets you define all the REST actions you like as regular Dancer route
handlers, without explicitly handling the outgoing data format.

=head2 resource

This keyword lets you declare a resource your application will handle.

    resource user =>
        create => sub { # create a new user with params->{user} },
        read   => sub { # return user where id = params->{id}   },
        delete => sub { # delete user where id = params->{id}   },
        update => sub { # update user with params->{user}       },
        index  => sub { # retrieve all users                    };

    # this defines the following routes:
    # GET /user/:id
    # GET /user/:id.:format
    # GET /user
    # GET /user.:format
    # POST /user
    # POST /user.:format
    # DELETE /user/:id
    # DELETE /user/:id.:format
    # PUT /user/:id
    # PUT /user/:id.:format

=head2 helpers

Some helpers are available. This helper will set an appropriate HTTP status for you.

=head3 status_ok

    status_ok({users => {...}});

Set the HTTP status to 200

=head3 status_created

    status_created({users => {...}});

Set the HTTP status to 201

=head3 status_accepted

    status_accepted({users => {...}});

Set the HTTP status to 202

=head3 status_bad_request

    status_bad_request("user foo can't be found");

Set the HTTP status to 400. This function as for argument a scalar that will be used under the key B<error>.

=head3 status_not_found

    status_not_found("users doesn't exists");

Set the HTTP status to 404. This function as for argument a scalar that will be used under the key B<error>.

=head1 LICENCE

This module is released under the same terms as Perl itself.

=head1 AUTHORS

This module has been written by Alexis Sukrieh C<< <sukria@sukria.net> >> and Franck
Cuny.

=head1 SEE ALSO

L<Dancer> L<http://en.wikipedia.org/wiki/Representational_State_Transfer>

=cut
