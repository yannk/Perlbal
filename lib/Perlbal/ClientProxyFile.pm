package Perlbal::ClientProxyFile;
use strict;
use warnings;
use base "Perlbal::ClientProxy";
no  warnings qw(deprecated);

use Perlbal::Util;
use Perlbal::ReproxyManager;
use Perlbal::HTTPHeaders;

use fields (
    'reproxy_expected_size',    # int: size of response we expect to get back for reproxy
    'primary_res_hdrs',
);

sub new_from_clientproxy {
    my $class = shift;
    my Perlbal::ClientProxy $cp = shift;
    Perlbal::Util::rebless($cp, $class);
    $cp->init;
    return $cp;
}

sub init {
    my Perlbal::ClientProxyFile $self = $_[0];
    $self->{reproxy_expected_size} = undef;
    $self->{primary_res_hdrs} = $self->{res_headers}->clone; # XXX is clone the right thing
}

sub start_reproxy_file {
    my Perlbal::ClientProxyFile $self = shift;
    my $file = shift;              # filename to reproxy
    my $hd = $self->{primary_res_hdrs}; # headers from backend, in need of cleanup

    # at this point we need to disconnect from our backend
    $self->{backend} = undef;

    # call hook for pre-reproxy
    return if $self->{service}->run_hook("start_file_reproxy", $self, \$file);

    # set our expected size
    if (my $expected_size = $hd->header('X-REPROXY-EXPECTED-SIZE')) {
        $self->{reproxy_expected_size} = $expected_size;
    }

    # start an async stat on the file
    $self->state('wait_stat');
    Perlbal::AIO::aio_stat($file, sub {

        # if the client's since disconnected by the time we get the stat,
        # just bail.
        return if $self->{closed};

        my $size = -s _;

        unless ($size) {
            # FIXME: POLICY: 404 or retry request to backend w/o reproxy-file capability?
            return $self->_simple_response(404);
        }
        if (defined $self->{reproxy_expected_size} && $self->{reproxy_expected_size} != $size) {
            # 404; the file size doesn't match what we expected
            return $self->_simple_response(404);
        }

        # if the thing we're reproxying is indeed a file, advertise that
        # we support byte ranges on it
        if (-f _) {
            $hd->header("Accept-Ranges", "bytes");
        }

        my ($status, $range_start, $range_end) = $self->{req_headers}->range($size);
        my $not_satisfiable = 0;

        if ($status == 416) {
            $hd = Perlbal::HTTPHeaders->new_response(416);
            $hd->header("Content-Range", $size ? "bytes */$size" : "*");
            $not_satisfiable = 1;
        }

        # change the status code to 200 if the backend gave us 204 No Content
        $hd->code(200) if $hd->response_code == 204;

        # fixup the Content-Length header with the correct size (application
        # doesn't need to provide a correct value if it doesn't want to stat())
        if ($status == 200) {
            $hd->header("Content-Length", $size);
        } elsif ($status == 206) {
            $hd->header("Content-Range", "bytes $range_start-$range_end/$size");
            $hd->header("Content-Length", $range_end - $range_start + 1);
            $hd->code(206);
        }

        # don't send this internal header to the client:
        $hd->header('X-REPROXY-FILE', undef);

        # rewrite some other parts of the header
        $self->setup_keepalive($hd);

        # just send the header, now that we cleaned it.
        $self->{res_headers} = $hd;
        $self->write($hd->to_string_ref);

        if ($self->{req_headers}->request_method eq 'HEAD' || $not_satisfiable) {
            $self->write(sub { $self->http_response_sent; });
            return;
        }

        $self->state('wait_open');
        Perlbal::AIO::aio_open($file, 0, 0 , sub {
            my $fh = shift;

            # if client's gone, just close filehandle and abort
            if ($self->{closed}) {
                CORE::close($fh) if $fh;
                return;
            }

            # handle errors
            if (! $fh) {
                # FIXME: do 500 vs. 404 vs whatever based on $! ?
                return $self->_simple_response(500);
            }

            # seek if partial content
            if ($status == 206) {
                sysseek($fh, $range_start, &POSIX::SEEK_SET);
                $size = $range_end - $range_start + 1;
            }

            $self->reproxy_fh($fh, $size);
            $self->watch_write(1);
        });
    });
}

1;
