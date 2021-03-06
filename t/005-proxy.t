#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::Mojo::Plack;
use Data::Dumper;
use Image::Size;
use File::Temp qw/tempdir/;

use File::Slurp;

use_ok 'Pipr::WS';

my $t = Test::Mojo::Plack->new('Pipr::WS');

my $test_image_path = "public/images/test.png";

my $res = $t->get_ok("/test/p/$test_image_path")->status_is(200)->tx->res;

is($res->headers->header('Content-Type'), 'image/x-png', 'Correct MIME-Type');

my $proxied_file = $res->body;
my $orig_file = File::Slurp::read_file("share/$test_image_path", binmode => ':raw');
is($proxied_file, $orig_file, 'Files are identical');

done_testing;
