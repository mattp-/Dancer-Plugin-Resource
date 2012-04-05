package Dancer::Plugin::REST;

use strict;
use warnings;

use Carp 'croak';
use Dancer ':syntax';
use Dancer::Plugin;

our $AUTHORITY = 'SUKRIA';
our $VERSION   = '0.07';

use base 'Exporter';

my $content_types = {
    json => 'application/json',
    yml  => 'text/x-yaml',
    xml  => 'application/xml',
};

my %routes;
my $inflect;

sub import {
    my ($class, @args) = @_;
    my @final_args;

    for my $arg (@args) {
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

    my $param_string = ':id';
    my ($old_prefix, $parent_prefix);

    # we only want one of these, read takes precedence
    $triggers{read} = $triggers{get} if ref $triggers{read} ne 'CODE';

    if ($inflect) {

        # if member => 'foo' is passed, turn it into an array
        for my $type (qw/member collection/) {
            if ($triggers{$type} && ref $triggers{$type} eq q{}) {
                $triggers{$type} = [$triggers{$type}];
            }
        }

        # if this resource is a nested child resource, manage the prefix
        $old_prefix = Dancer::App->current->prefix || q{};
        $parent_prefix = q{};

        if ($triggers{parent} and $routes{$triggers{parent}}) {
            prefix $parent_prefix = $routes{$triggers{parent}};
        }
        else {
            $parent_prefix = $old_prefix;
        }

        # we only want one of these, read takes precedence
        $triggers{read} = $triggers{get} if !$triggers{read};

        for my $func (qw/load load_all/) {
            $triggers{$func} = sub { }
              if ref $triggers{$func} ne 'CODE';
        }

 # by default take the singular resource as the param name (ie :user for users)
        my $singular = Lingua::EN::Inflect::Number::to_S($resource);
        my $params   = ["${singular}"];

# or if the user wants to override to take multiple params, ie /user/:foo/:bar/:baz
# allow it. This could be useful for composite key schemas
        if ($triggers{params}) {
            $params =
                ref $triggers{params} eq 'ARRAY' ? $triggers{params}
              : ref $triggers{params} eq q{}     ? [$triggers{params}]
              :                                    $params;
        }

        $param_string = join '/', map {":${_}_id"} @{$params};

        my ($package) = caller;

        for my $verb (qw/create get read update delete index/) {

            # if get_foo is defined, use that.
            if ($verb eq 'index') {
                if (my $func =
                    _function_exists("${package}::${verb}_${resource}"))
                {
                    $triggers{$verb} ||= sub {
                        $func->($triggers{load_all}->(), @_);
                    };
                }
            }
            else {
                if (my $func =
                    _function_exists("${package}::${verb}_${singular}"))
                {
                    $triggers{$verb} ||= sub {
                        if ($verb eq 'create') {
                            $func->(@_);
                        }
                        else {
                            $func->($triggers{load}->(), @_);
                        }
                    };
                }
            }

            # if we've gotten this far, no route exists. use a default
            $triggers{$verb}
              ||= sub { status_method_not_allowed('Method not allowed.'); };
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
                if (my $func = _function_exists(
                        "${package}::${verb}_${singular}_${member}")
                  )
                {
                    $wrap = sub { $func->($triggers{load}->(), @_); };
                }
                else {

                    # default to 405 method not allowed
                    $wrap =
                      sub { status_method_not_allowed('Method not allowed.'); };
                }

                # register it
                $verb2action{$verb}
                  ->("/${resource}/${param_string}/${member}", $wrap);
                $verb2action{$verb}
                  ->("/${resource}/${param_string}/${member}.:format", $wrap);
            }
        }

        for my $member (@{$triggers{collection}}) {

            for my $verb (qw/create read update delete/) {

                # try and find the method via caller package
                my $wrap;
                if (my $func = _function_exists(
                        "${package}::${verb}_${resource}_${member}")
                  )
                {
                    $wrap = sub { $func->($triggers{load_all}->(), @_); };
                }
                else {

                    # default to 405 method not allowed
                    $wrap =
                      sub { status_method_not_allowed('Method not allowed.'); };
                }

                # register it
                $verb2action{$verb}->("/${resource}/${member}",         $wrap);
                $verb2action{$verb}->("/${resource}/${member}.:format", $wrap);
            }
        }
    }
    else {
        for my $key (qw/params load load_all member collection parent/) {
            croak
              qq{You must "use Dancer::Plugin::REST ':inflect';" to enable these features.}
              if defined $triggers{$key};
        }
    }

    # we don't croak on index since it was introduced post 0.07
    if (ref $triggers{index} eq 'CODE') {
        get "/${resource}.:format" => $triggers{index};
        get "/${resource}"         => $triggers{index};
    }

    croak "resource should be given with triggers"
      unless defined $resource
          and defined $triggers{get}
          and defined $triggers{update}
          and defined $triggers{delete}
          and defined $triggers{create};

    post "/${resource}.:format" => $triggers{create};
    post "/${resource}"         => $triggers{create};

    get "/${resource}/${param_string}.:format" => $triggers{read};
    get "/${resource}/${param_string}"         => $triggers{read};

    put "/${resource}/${param_string}.:format" => $triggers{update};
    put "/${resource}/${param_string}"         => $triggers{update};

    del "/${resource}/${param_string}.:format" => $triggers{delete};
    del "/${resource}/${param_string}"         => $triggers{delete};

    if ($inflect) {

# save every defined resource if it is referred as a parent in a nested child resource
        $routes{$resource} = "${parent_prefix}/${resource}/${param_string}";

        # restore existing prefix if saved
        prefix $old_prefix if $old_prefix;
    }
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
        if ($code >= 400 && ref $_[0] eq q{}) {
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

By default, you can pass in a mapping of CRUD actions to subrefs that will align
to auto-generated routes:

    resource user =>
        create => sub { # create a new user with params->{user} },
        read   => sub { # return user where id = params->{id}   },
        delete => sub { # delete user where id = params->{id}   },
        update => sub { # update user with params->{user}       },
        index  => sub { # retrieve all users                    };

    # this defines the following routes:
    # POST /user
    # POST /user.:format
    # GET /user/:id
    # GET /user/:id.:format
    # PUT /user/:id
    # PUT /user/:id.:format
    # DELETE /user/:id
    # DELETE /user/:id.:format
    # GET /user
    # GET /user.:format

As of Dancer::Plugin::REST 0.08, a more robust implementation inspired by
Rails and Catalyst::Action::REST is enabled when you import with the ':inflect'
keyword:

    use Dancer::Plugin::REST ':inflect';

    resource 'users',
        member => [qw/posts/],
        collection => [qw/log/],
        load => sub { $schema->User->find(param 'user_id'); },
        load_all => sub { $schema->User->all; };

    resource 'accounts',
        parent => 'user',
        params => [qw/composite key/];

    # HTTP $VERB_$RESOURCE is mapped automatically for actions on the resource

    # GET /users
    sub index_users {
        my ($users) = @_;   # returnval of load_all is passed in
    }

    # HTTP $VERB_$SINGULAR is mapped automatically for actions on elements of the resource

    # POST /users
    sub create_user {
        # ...
    }

    # GET /users/:user_id
    sub read_user {
        my ($user) = @_;    # returnval of load is passed in
        # ...
    }

    # param id is inflected from the plural resource
    # PUT /users/:user_id
    sub update_user { my ($user) = @_; }

    # DELETE /users/:user_id
    sub delete_user { my ($user) = @_; }

    # The member collection is attached to the members of the resource
    # All CRUD verbs are automatically mapped
    # GET /users/:user_id/posts
    sub read_user_posts { }

    # likewise for collection methods
    # POST /users/logs
    sub create_users_logs { }

    # The accounts resource nests underneath user with the parent keyword
    # the params keyword overrides the default params set by the route
    # POST /users/:user_id/accounts
    sub create_account { }

    # GET /users/:user_id/accounts/:composite/:key
    sub read_account { }

Using ':inflect' requires Lingua::EN::Inflect::Number to singularize plural resources.

Mapping CRUD methods to routes is done automatically by inspecting the symbol table.

A full list of keywords that can be passed to resource is listed below. All are
optional.

=head3 params

Defines the list of params that the given resource takes in its part of the
path. Takes scalar or arrayref for 1 or multiple params.
    resource 'users', params => [qw/foo bar/]; # /users/:foo/:bar

=head3 load/load_all

Takes a coderef. Methods called on element of the resource (read/update/delete)
will receive load returnval in @_.  Methods on the resource itself (index) will
receive load_all in @_. Create does not receive any arguments. An alternative
to @_ would be to use Dancers's 'vars' functionality for scope outside of the
given route.

=head3 member

Declares additional methods attached to the given resource. Takes either a
scalar or an arrayref.

    resource 'users', member => 'posts';
    sub read_users_posts { } # GET /users/:user_id/posts

=head3 collection

Like member methods, but attached to the root resource, and not the instance.

    resource 'users', collection => [qw/posts/];
    sub create_users_posts { } # POST /users/posts

=head3 parent

Each time a resource is declared its prefix and route is stored internally. If
you declare a resource as a child of an already defined resource, the parents
resource will be set as a prefix automatically, and the old prefix will be
restored when done.

    resource 'users';
    resource 'posts', parent => 'users';
    resource 'comments', parent => 'posts';

    # /users/:user_id
    # /users/:user_id/posts/:post_id
    # /users/:user_id/posts/:post_id/comments/:comment_id

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
Cuny. :inflect resource functionality written by Matthew Phillips C<< <mattp@cpan.org> >>.

=head1 SEE ALSO

L<Dancer> L<http://en.wikipedia.org/wiki/Representational_State_Transfer>

=cut
