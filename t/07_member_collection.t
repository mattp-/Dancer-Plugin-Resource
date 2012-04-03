use strict;
use warnings;
use Dancer::ModuleLoader;
use Test::More import => ['!pass'];

plan tests => 12;
{

    package Webservice;
    use Dancer;
    use Dancer::Plugin::REST ':inflect';
    use Test::More import => ['!pass'];

    resource 'users';

    resource 'posts',
        load => sub { 9 },
        load_all => sub { 88 },
        parent => 'users',
        member => 'comments',
        collection => [qw/logs/];

    resource 'pongs',
        parent => 'posts';

    sub read_post_comments {
        is($_[0], 9, 'load sub retval passed in to @_');
        ok (1, 'get_post_comments reached.');
        my $id = params->{'post_id'};
        ok ($id == 222, 'proper param id generated');
        status_ok({ msg => "chain reached" });
    }

    sub index_posts {
        is($_[0], 88, 'load_all sub retval passed in to @_');
        ok (1, 'index_posts reached.');
        status_ok({ msg => "chain reached" });
    }

    sub read_users_logs {
        ok (1, 'get_users_log reached.');
        status_ok({ msg => "chain reached" });
    }

    sub read_pong {
        ok (1, 'put_pongs reached.');
        status_ok({ msg => "chain reached" });
    }
}

use Dancer::Test;

my $r = dancer_response( GET => '/users/1/posts/222/comments' );
is $r->{status}, 200, 'HTTP code is 200';
is $r->{content}->{msg}, 'chain reached', 'Expected content returned';

$r = dancer_response( GET => '/users/5/posts' );
is $r->{status}, 200, 'HTTP code is 200';
is $r->{content}->{msg}, 'chain reached', 'Expected content returned';

$r = dancer_response( GET => '/users/1/posts/222/pongs/555' );
is $r->{status}, 200, 'HTTP code is 200';

$r = dancer_response( PUT => '/users/1/posts/222/pongs/555' );
is $r->{status}, 405, 'HTTP code is 405 on missing methods';
