package Perlbal::Plugin::BackendURLRedirect;

use 5.006;

use strict;
use warnings;

use Perlbal;
use Perlbal::ClientProxyRedirectURL; # XXX ClientReproxyURL?

our $VERSION = "0.00_01";
$VERSION = eval $VERSION;

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;
    $svc->register_hook('BackendURLRedirect', 'backend_response_received', \&backend_response_received);
    $svc->register_hook('BackendURLRedirect', 'backend_client_assigned', \&backend_client_assigned);
    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;
    $svc->unregister_hook('BackendURLRedirect', 'backend_response_received');
    $svc->unregister_hook('BackendURLRedirect', 'backend_client_assigned');
    return 1;
}

sub load {
    Perlbal::Service::add_tunable(
        # allow the following:
        #    SET myservice.echo_delay = 5
        buffer_size_redirect_url => {
            default => "50k",
            des => "How much we'll get ahead of a client we'll get while copying from a reproxied URL to a client.  If a client gets behind this much, we stop reading from the reproxied URL for a bit.  The default is lower than the regular buffer_size (50k instead of 256k) because it's assumed that you're only reproxying to large files on event-based webservers, which are less sensitive to many open connections, whereas the 256k buffer size is good for keeping heavy process-based free of slow clients.",
            check_type => "size",
            check_role => "reverse_proxy",
        },
    );

    return 1;
}

sub unload {
    Perlbal::Service::remove_tunable('buffer_size_redirect_url');
    return 1;
}

## advertise our X-Proxy-Capabilities
sub backend_client_assigned {
    my $be = shift;
    my $svc = $be->{service} or return;
    my $hds = $be->{req_headers};
    $hds->header("X-Proxy-Capabilities", "reproxy-file");
    return 0; # Continue processing of other hooks
}

sub backend_response_received {
    my Perlbal::BackendHTTP $be = shift;
    my Perlbal::HTTPHeaders $res_hd = $be->{res_headers};
    my $client = $be->{client};
    my Perlbal::HTTPHeaders $req_hd = $client->{req_headers};

    # standard handling ## Is that important?
    #$self->state("xfer_res");
    #$client->state("xfer_res");
    #$self->{has_attention} = 1;

    $client->{res_headers} = $res_hd->clone;

    ## We already have done a backend redirect, now we handle the second
    ## backend response
    if ($client->isa('Perlbal::ClientProxyRedirectURL')) {
        ## this is the second backend response
        my $thd = $client->{primary_res_hdrs}; ## old behaviour
        $thd->header('Content-Length', $res_hd->header('Content-Length'));
        $thd->header('X-REPROXY-FILE', undef);
        $thd->header('X-REPROXY-URL', undef);
        $thd->header('X-REPROXY-EXPECTED-SIZE', undef);
        $thd->header('X-REPROXY-CACHE-FOR', undef);

        # also update the response code, in case of 206 partial content
        my $rescode = $res_hd->response_code;
        if ($rescode == 206 || $rescode == 416) {
            $thd->code($rescode);
            $thd->header('Accept-Ranges', $res_hd->header('Accept-Ranges')) if $res_hd->header('Accept-Ranges');
            $thd->header('Content-Range', $res_hd->header('Content-Range')) if $res_hd->header('Content-Range');
        }
        $thd->code(200) if $res_hd->response_code == 204;  # upgrade HTTP No Content (204) to 200 OK.
        $be->{res_headers} = $thd; # old behavior, swap headers
        return 0; # continue Perlbal processing
    }

    my $urls = $res_hd->header('X-REPROXY-URL')
        or return 0; ## not a redirect, let's continue in Perlbal

    $be->next_request; ## free the initial backend
    my $cp = Perlbal::ClientProxyRedirectURL->new_from_clientproxy($client);
    $cp->start_reproxy_uri($urls);
    return 1; # stop regular processing
}

1;
