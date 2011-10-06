package Perlbal::Plugin::BackendServiceRedirect;

use 5.006;

use strict;
use warnings;

use Perlbal;

our $VERSION = "0.00_01";
$VERSION = eval $VERSION;

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;
    $svc->register_hook('BackendServiceRedirect', 'backend_response_received', \&backend_response_received);
    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;
    $svc->unregister_hook('BackendServiceRedirect', 'backend_response_received');
    return 1;
}

sub backend_response_received {
    my Perlbal::BackendHTTP $be = shift;
    my Perlbal::HTTPHeaders $res_hd = $be->{res_headers};
    my Perlbal::ClientProxy $client = $be->{client};
    my Perlbal::HTTPHeaders $req_hd = $client->{req_headers};
    return 0; # Continue processing in perlbal
}

1;
