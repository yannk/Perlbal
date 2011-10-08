## This should probably be in the Plugin namespace
package Perlbal::ClientProxyRedirectURL;
use strict;
use warnings;
use base "Perlbal::ClientProxy";
no  warnings qw(deprecated);

use Perlbal::Util;
use Perlbal::ReproxyManager;
use Perlbal::HTTPHeaders;

use fields (
    'reproxy_uris',             # arrayref; URIs to reproxy to, in order
    'reproxy_expected_size',    # int: size of response we expect to get back for reproxy
    'currently_reproxying',     # arrayref; the host info and URI we're reproxying right 
    'primary_res_hdrs',         # if defined, we are doing a transparent reproxy-URI
                                # and the headers we get back aren't necessarily
                                # the ones we want.  instead, get most headers
                                # from the provided res headers object here.
);

sub new_from_clientproxy {
    my $class = shift;
    my Perlbal::ClientProxy $cp = shift;
    Perlbal::Util::rebless($cp, $class);
    $cp->init;
    return $cp;
}

sub init {
    my Perlbal::ClientProxyRedirectURL $self = $_[0];

    $self->{reproxy_uris} = undef;
    $self->{reproxy_expected_size} = undef;
    $self->{currently_reproxying} = undef;
    $self->{primary_res_hdrs} = $self->{res_headers}->clone; # XXX is clone the right thing
}

# returns true if this ClientProxy is too many bytes behind the backend
sub too_far_behind_backend {
    my Perlbal::ClientProxyRedirectURL $self = $_[0];
    my Perlbal::BackendHTTP $backend = $self->{backend}   or return 0;

    # use a special buffer size for reproxy_url:
    # assumption is that reproxied-to webservers are event-based and it's okay
    # to tie the up longer in favor of using less buffer memory in
    # perlbal)
    my $max_buffer = $self->{service}->{extra_config}
                          ->{buffer_size_redirect_url};
    return $self->{write_buf_size} > $max_buffer;
}

sub as_string {
    my $self = shift;
    my $ret = $self->SUPER::as_string(@_);
    $ret .= "; reproxying" if $self->{currently_reproxying};
    return $ret;
}

# call this with a string of space separated URIs to start a process
# that will fetch the item at the first and return it to the user,
# on failure it will try the second, then third, etc
sub start_reproxy_uri {
    my Perlbal::ClientProxyRedirectURL $self = $_[0];
    my $urls = $_[1];
    my $primary_res_hdrs = $self->{primary_res_hdrs};

    # at this point we need to disconnect from our backend
    $self->{backend} = undef;

    # failure if we have no primary response headers
    return unless $primary_res_hdrs;

    # construct reproxy_uri list
    if (defined $urls) {
        my @uris = split /\s+/, $urls;
        $self->{currently_reproxying} = undef;
        $self->{reproxy_uris} = [];
        foreach my $uri (@uris) {
            next unless $uri =~ m!^http://(.+?)(?::(\d+))?(/.*)?$!;
            push @{$self->{reproxy_uris}}, [ $1, $2 || 80, $3 || '/' ];
        }
    }

    # if we get in here and we have currently_reproxying defined, then something
    # happened and we want to retry that one
    if ($self->{currently_reproxying}) {
        unshift @{$self->{reproxy_uris}}, $self->{currently_reproxying};
        $self->{currently_reproxying} = undef;
    }

    # if we have no uris in our list now, tell the user 503
    return $self->_simple_response(503)
        unless @{$self->{reproxy_uris} || []};

    # set the expected size if we got a content length in our headers
    if ($primary_res_hdrs && (my $expected_size = $primary_res_hdrs->header('X-REPROXY-EXPECTED-SIZE'))) {
        $self->{reproxy_expected_size} = $expected_size;
    }

    # pass ourselves off to the reproxy manager
    $self->state('wait_backend');
    Perlbal::ReproxyManager::do_reproxy($self);
}

sub try_next_uri {
    my Perlbal::ClientProxyRedirectURL $self = $_[0];

    if ($self->{currently_reproxying}) {
        # If we're currently reproxying to a backend, that means we want to try the next uri which is
        # ->{reproxy_uris}->[0].
    } else {
        # Since we're not currently reproxying, that means we never got a backend in the first place,
        # so we want to move on to the next uri which is ->{reproxy_uris}->[1] (shift one off)
        shift @{$self->{reproxy_uris}};
    }

    $self->{currently_reproxying} = undef;

    $self->start_reproxy_uri();
}

sub use_reproxy_backend {
    my Perlbal::ClientProxyRedirectURL $self = $_[0];
    my Perlbal::BackendHTTP $be = $_[1];

    # get a URI
    my $datref = $self->{currently_reproxying} = shift @{$self->{reproxy_uris}};
    unless (defined $datref) {
        # return error and close the backend
        $be->close('invalid_uris');
        return $self->_simple_response(503);
    }

    # now send request
    $self->{backend} = $be;
    $be->{client} = $self;

    my $extra_hdr = "";
    if (my $range = $self->{req_headers}->header("Range")) {
        $extra_hdr .= "Range: $range\r\n";
    }
    if (my $host = $self->{req_headers}->header("Host")) {
        $extra_hdr .= "Host: $host\r\n";
    }

    my $req_method = $self->{req_headers}->request_method eq 'HEAD' ? 'HEAD' : 'GET';
    my $headers = "$req_method $datref->[2] HTTP/1.0\r\nConnection: keep-alive\r\n${extra_hdr}\r\n";

    $be->{req_headers} = Perlbal::HTTPHeaders->new(\$headers);
    $be->state('sending_req');
    $self->state('backend_req_sent');
    $be->write($be->{req_headers}->to_string_ref);
    $be->watch_read(1);
    $be->watch_write(1);
}

sub backend_response_received {
    my Perlbal::ClientProxyRedirectURL $self = $_[0];
    my Perlbal::BackendHTTP $be = $_[1];

    # we fail if we got something that's NOT a 2xx code, OR, if we expected
    # a certain size and got back something different
    my $code = $be->{res_headers}->response_code + 0;

    my $bad_code = sub {
        return 0 if $code >= 200 && $code <= 299;
        return 0 if $code == 416;
        return 1;
    };

    my $bad_size = sub {
        return 0 unless defined $self->{reproxy_expected_size};
        return $self->{reproxy_expected_size} != $be->{res_headers}->header('Content-length');
    };

    if ($bad_code->() || $bad_size->()) {
        # fall back to an alternate URL
        $be->{client} = undef;
        $be->close('non_200_reproxy');
        $self->try_next_uri;
        return 1;
    }

    # a response means that we are no longer currently waiting on a reproxy, and
    # don't want to retry this URI
    $self->{currently_reproxying} = undef;

    return 0;
}

# called when we've finished writing everything to a client and we need
# to reset our state for another request.  returns 1 to mean that we should
# support persistence, 0 means we're discarding this connection.
sub http_response_sent {
    my Perlbal::ClientProxyRedirectURL $self = $_[0];

    ## ok, let's downgrade ourselves (similar to return_to_base)
    ## since persist_client might be on, we want the next proxy client
    ## class to be the regular one.
    Perlbal::Util::rebless($self, 'Perlbal::ClientProxy');
    $self->http_response_sent;
}

1;
