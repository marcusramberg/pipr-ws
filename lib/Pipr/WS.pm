package Pipr::WS;

our $VERSION = '18.0.0';


use Digest::MD5 'md5_hex';
use Encode;
use HTML::TreeBuilder;
use Image::Size;
use Mojo::DOM;
use Mojo::Collection 'c';
use Mojo::File 'path';
use Mojo::URL;
use Mojo::UserAgent::Cached;
use POSIX 'strftime';

use Mojolicious::Lite -signatures;


my $config=plugin 'Config';
plugin 'Thumbnail';





#set 'appdir' => eval { dist_dir('Pipr-WS') } || File::Spec->catdir(config->{appdir}, 'share');

#set 'confdir' => File::Spec->catdir(config->{appdir});

#set 'envdir'  => File::Spec->catdir(config->{appdir}, 'environments');
#set 'public'  => File::Spec->catdir(config->{appdir}, 'public');
#set 'views'   => File::Spec->catdir(config->{appdir}, 'views');
#
helper get_url => sub {
    my ($c, $strip_prefix) = @_;

    my $request_uri = $c->request->url;
    $request_uri =~ s{ \A /? \Q$strip_prefix\E /? }{}gmx;

    # if we get an URL like: http://pipr.opentheweb.org/overblikk/resized/300x200/http://g.api.no/obscura/external/9E591A/100x510r/http%3A%2F%2Fnifs-cache.api.no%2Fnifs-static%2Fgfx%2Fspillere%2F100%2Fp1172.jpg
    # We want to re-escape the external URL in the URL (everything is unescaped on the way in)
    # NOT needed?
    #    $request_uri =~ s{ \A (.+) (http://.*) \z }{ $1 . URI::Escape::uri_escape($2)}ex;

    return $request_uri;
};

helper cached_ua => sub {
    state $ua=Mojo::UserAgent::Cached->new()->insecure(1)->timeout($config->{timeout});
    return $ua;
};


get '/' => sub {
    my $c = shift;
    $c->render('index' => { sites => $config->{sites} }) if $c->mode ne 'production';
};

# Proxy images
get '/:site/p/*url' => sub {
     my $c = shift;
    my ( $site, $url ) = $c->stash->{qw/site url/};

    $url = $c->get_url("$site/p");

    my $site_config = $config->{sites}->{ $site };
    $site_config->{site} = $site;
    if ($config->{restrict_targets}) {
        $c->render(status=>401, text=>'Invalid site');
    }
    $c->stash(site_config => $site_config);

    my $file = path($c->get_image_from_url($url));

    # try to get stat info
    my @stat = stat $file or do {
        return $c->render(status=>404, text=>'File not found')
    };

    # prepare Last-Modified header
    my $lmod = strftime '%a, %d %b %Y %H:%M:%S GMT', gmtime $stat[9];

    # processing conditional GET
    if ( ( $c->req->header->if_modified_since || '' ) eq $lmod ) {
        return $c->render(status=>304, text=> 'Not modified');
    }


    my $ft = File::Type->new();

    # send useful headers & content
    $c->res->headers->cache_control('public, max-age=86400');
    $c->res->headers->last_modified($lmod);
    $c->res->headers->content_type($ft->mime_type($file));
    $c->render(data => $file->slurp);

};

get '/:site/dims/*url' => sub {
    my $c= shift;
    my ( $site, $url ) = $c->stash->{qw/site url/};

    $url = $c->get_url("$site/dims");

    my $local_image = $c->get_image_from_url($url);
    my ( $width, $height, $type ) = Image::Size::imgsize($local_image);

    return $c->render(json => {
        image => { type => lc $type, width => $width, height => $height }
    });
};

# support uploadcare style
get '/:$site/-/:cmd/:params/:param2/*url' => sub {
   my $c = shift;
   my ($site, $cmd, $params, $param2, $url ) = $c->stash->{qw/site cmd params param2 url/};

   $url = $c->get_url("$site/-/$cmd/$params/$param2");

   if ($cmd eq 'scale_crop' && $param2 eq 'center') {
       return gen_image($site, 'scale_crop_centered', $params, $url);
   }
   return $c->render(text=>'illegal command', status => '401');
};

get '/:site/:cmd/:params/*url' => sub {
   my $c=shift;
   my ($site, $cmd, $params, $url ) = $c->stash->{qw/site cmd params url/};

    $url = get_url("$site/$cmd/$params");

    return gen_image($site, $cmd, $params, $url);
};

sub gen_image {
    my ($c,$site, $cmd, $params, $url) = @_;

    return $c->render(status=>401, text=>'no site set') if !$site;
    return $c->render(status=>401, text=>'no command specified') if !$cmd;
    return $c->render(status=>401, text=>'no params set') if !$params;
    return $c->render(status=>401, text=>'no url set') if !$url;

    my $site_config = $config->{sites}->{ $site };
    $site_config->{site} = $site;
    if ($config->{restrict_targets}) {
      return $c->render(status=>401, text=>'invalid site') if !$site_config;
    }
    $c->stash('site_config' => $site_config);

    my ( $format, $offset ) = split /,/, $params;
    my ( $x,      $y )      = split /x/, $offset || '0x0';
    my ( $width,  $height ) = split /x/, $format;

    if ( $config->{restrict_targets} ) {
        my $info = "'$url' with '$params'";
        $c->app->log->debug("checking $info");
        return $c->render(status=>401, text=>"no matching targets: $info")
            unless c(@{ $site_config->{allowed_targets} }, keys %{ $site_config->{shortcuts} || {} })
              ->first(sub { $url =~ m{ $_ }gmx; });
        return $c->render(status=>401, text=>"no matching sizes: $info")
            unless c( $site_config->{sizes} )
              ->first(sub { $format =~ m{\A \Q$_\E \z}gmx; });
    }

    my $local_image = $c->get_image_from_url($url);
    return $c->render(status=>501, text=>"unable to download picture: $url")
      if !$local_image;

    my $thumb_cache = path($config->{plugins}->{Thumbnail}->{cache})->child($site)->list_tree;

    $c->res->headers->cache_control('public, max-age=86400');

    my $switch = {
        'resized' => sub {
            my ($local_image, $width, $height, $x, $y, $thumb_cache) = @_;
            return resize $local_image => {
              w => $width, h => $height, s => 'force'
            },
            {
              format => 'jpeg', quality => '100', cache => $thumb_cache, compression => 7
            }
        },
        'scale_crop_centered' => sub {
            my ($local_image, $width, $height, $x, $y, $thumb_cache) = @_;
            return thumbnail $local_image => [
                  resize => {
                    w => $width, h => $height, s => 'min'
                  },
                  crop => {
                    w => $width, h => $height, a => 'cm'
                  },
            ],
            {
              format => 'jpeg', quality => '100', cache => $thumb_cache, compression => 7
            };
        },
        'cropped' => sub  {
            my ($local_image, $width, $height, $x, $y, $thumb_cache) = @_;
            return thumbnail $local_image => [
                crop => {
                    w => $width + $x, h => $height + $y, a => 'lt'
                },
                crop => {
                    w => $width, h => $height, a => 'rb'
                },
            ],
            {
              format => 'jpeg', quality => '100', cache => $thumb_cache, compression => 7
            };
        },
        'thumbnail' => sub {
            my ($local_image, $width, $height, $x, $y, $thumb_cache) = @_;
            return thumbnail $local_image => [
                crop => {
                    w => 200, h => 200, a => 'lt'
                },
                resize => {
                    w => $width, h => $height, s => 'min'
                },
            ],
            {
              format => 'jpeg', quality => '100', cache => $thumb_cache, compression => 7
            };
        },
        'default' => sub {
            return $c->render(status=>401, text=>"unknown command: $cmd")
        }
  };

  eval {
      my $body = $switch->{$cmd} ? $switch->{$cmd}->($local_image, $width, $height, $x, $y, $thumb_cache) : $switch->{'default'}->();
      die $body if $body =~ /Internal Server Error/;
      return $body;
  } or do {
      return $c->render(status=>400, text=>"Unable to load image: $@")
  };
};

sub get_image_from_url {
    my ($c, $url) = @_;

    my $local_image = download_url($url);
    my $ft          = File::Type->new();

    return if !$local_image;
    return if !-e $local_image;

    return $local_image
      if ( $ft->checktype_filename($local_image) =~ m{ \A image }gmx );

    $c->app->log->debug("fetching image from '$local_image'");

    my $res = $c->cached_ua->get("file://$local_image");
    my $dom = Mojo::DOM->new( $res->decoded_content );
    my $el  = $dom->at( 'meta[property="og:image"]' );

    my $image_url = $el && $el->attr('content');

    if ( !$image_url ) {
        $el = $dom->find('img')->first(sub {
            $c->app->log->debug("$url: " . $_[0]->as_HTML);
            return ( $url =~ m{ dn\.no | nettavisen.no }gmx
                && defined $_[0]->attr('title') )
                || ( $url =~ m{ nrk\.no }gmx && $_[0]->attr('longdesc') );
            }
        );
        $image_url = $el && $el->attr('src');
    }

    if ($image_url) {
        my $u = Mojo::URL->new($image_url)->base($url)->to_abs;
        $image_url = $u->canonical;
        $c->log->app->debug("fetching: $image_url instead from web page");
        $local_image = $c->download_url( $image_url, $local_image, 1 );
    }

    return $local_image;
}

sub download_url {
    my ($c, $url, $local_file, $ignore_cache ) = @_;

    $url =~ s/\?$//;

    my $site_config = $c->stash('site_config');

    $c->app->log->debug("downloading url: $url");

    for my $path (keys %{$site_config->{shortcuts} || {}}) {
        if ($url =~ s{ \A /? $path }{}gmx) {
            my $target = expand_macros($site_config->{shortcuts}->{$path}, request->headers->{host});
            $url = sprintf $target, ($url);
            last;
        }
    }

    for my $repl (@{ $site_config->{replacements} || [] }) {
        $url =~ s/$repl->[0]/$repl->[1]/;
    }

    $url =~ s{^(https?):/(?:[^/])}{$1/}mx;

    if ($url !~ m{ \A (https?|ftp)}gmx) {
        if ( $config->{allow_local_access} ) {
            my $local_file = path( $config->{appdir}, $url )->slurp;
            $c->app->log->debug("locally accessing $local_file");
            return $local_file if $local_file;
        }
    }

    $local_file ||= File::Spec->catfile(
        (
            File::Spec->file_name_is_absolute( $config->{'cache_dir'} )
            ? ()
            : $config->{appdir}
        ),
        $config->{'cache_dir'},
        $site_config->{site},
        _url2file($url)
    );

    File::Path::make_path( dirname($local_file) );

    $c->app->log->debug('local_file: ' . $local_file);

    return $local_file if !$ignore_cache && -e $local_file;

    $c->app->log->debug("fetching from the net... ($url)");

    my $res = eval { $c->cached_ua->get($url, ':content_file' => $local_file); };
    return $c->render(status=>400, text=>"Error getting $url: (".(request->uri).")" . ($res ? $res->status_line : $@) . $c->dumper($site_config))
      unless ($res && $res->is_success);

    # Try fetching image from HTML page

    return (($res && $res->is_success) ? $local_file : ($res && $res->is_success));
}

sub _url2file {
  my ($url) = @_;

  $url = Mojo::URL->new($url);
  my $q = $url->query->to_hash;
  $url->query( map { ( $_ => $q->{$_} ) } sort keys %{ $q || {} } );
  $url = $url->to_string;

  my $md5 = md5_hex(encode_utf8($url));
  my @parts = ( $md5 =~ m/^(.)(..)/ );
  $url =~ s/\?(.*)/md5_hex($1)/e;
  $url =~ s{^https?://}{}; # treat https and http as the same file to save some disk cache
  $url =~ s/[^A-Za-z0-9_\-\.=?,()\[\]\$^:]/_/gmx;
  File::Spec->catfile(@parts,$url);
}

sub expand_macros {
    my ($str, $host) = @_;

    my $map = {
      qa  => 'kua',
      dev => 'dev',
      kua => 'kua',
    };

    $host =~ m{ \A (?:(dev|kua|qa)[\.-])pipr }gmx;
    my $env_subdomain = $1 && $map->{$1} || 'www';
    $str =~ s{%ENV_SUBDOMAIN%}{$env_subdomain}gmx;

    return $str;
}


1;

=pod

=head NAME

Pipr

=head1 DESCRIPTION

Picture Proxy/Provider/Presenter

=head1 AUTHOR

   Nicolas Mendoza <mendoza@pvv.ntnu.no>
   Marcus Ramberg <mramberg@cpan.org>

=cut
