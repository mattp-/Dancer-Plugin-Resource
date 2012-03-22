use strict;
use warnings;
use Dancer::ModuleLoader;
use Test::More import => ['!pass'];

plan tests => 10;

{

    package Webservice;
    use Dancer;
    use Dancer::Plugin::REST;

    resource user => 'get' => \&on_get_user,
      'create'    => \&on_create_user;

    my $users   = {};
    my $last_id = 0;

    sub on_get_user {
        my $id = params->{'id'};
        return status_bad_request('id is missing') if !defined $users->{$id};
        status_ok( { user => $users->{$id} } );
    }

    sub on_create_user {
        my $id   = ++$last_id;
        my $user = params('body');
        $user->{id} = $id;
        $users->{$id} = $user;

        status_created( { user => $users->{$id} } );
    }

    resource client => read => \&on_get_user, get => \&on_get_user;
}

use Dancer::Test;

my $r = dancer_response( GET => '/user/1' );
is $r->{status}, 400, 'HTTP code is 400';
is $r->{content}->{error}, 'id is missing', 'Valid content';

$r = dancer_response( POST => '/user', { body => { name => 'Alexis' } } );
is $r->{status}, 201, 'HTTP code is 201';
is_deeply $r->{content}, { user => { id => 1, name => "Alexis" } },
  "create user works";

$r = dancer_response( GET => '/user/1' );
is $r->{status}, 200, 'HTTP code is 200';
is_deeply $r->{content}, { user => { id => 1, name => 'Alexis' } },
  "user 1 is defined";

$r = dancer_response( DELETE => '/user/23', );
is $r->{status}, 405, 'HTTP code is 405';
is_deeply $r->{content}->{error}, 'Method not allowed.', 'valid content';

$r = dancer_response( GET => '/client/1' );
is $r->{status}, 200, 'HTTP code is 200';
is_deeply $r->{content}, { user => { id => 1, name => 'Alexis' } },
  "Read properly takes precedence over get alias."
