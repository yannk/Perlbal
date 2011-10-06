package Perlbal::Plugin::FileRedirect;

use 5.006;

use strict;
use warnings;

use Perlbal;
use Perlbal::ClientProxyFile;

our $VERSION = "0.00_01";
$VERSION = eval $VERSION;

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;
    $svc->register_hook('FileRedirect', 'backend_response_received', \&backend_response_received);
    $svc->register_hook('FileRedirect', 'backend_client_assigned', \&backend_client_assigned);
    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;
    $svc->unregister_hook('FileRedirect', 'backend_response_received');
    $svc->unregister_hook('FileRedirect', 'backend_client_assigned');
    return 1;
}

sub load {1}
sub unload{1}


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

    my $filename = $res_hd->header('X-REPROXY-FILE');
    unless (defined $filename and length $filename) {
        return 0; ## not a file redirect, let's continue in Perlbal
    }

    $be->next_request; ## free the initial backend
    my $cp = Perlbal::ClientProxyFile->new_from_clientproxy($client);
    $cp->start_reproxy_file($filename);
    return 1; # stop regular processing
}

1;
