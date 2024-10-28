package Data::Mirror;
# ABSTRACT: a simple way to efficiently retrieve data from the World Wide Web.
use Carp;
use Digest::SHA qw(sha256_hex);
use Encode;
use File::Basename qw(basename);
use File::Slurp;
use File::Spec;
use File::stat;
use HTTP::Date;
use JSON::XS;
use List::Util qw(any max);
use LWP::UserAgent;
use POSIX qw(getlogin);
use Text::CSV_XS qw(csv);
use XML::LibXML;
use YAML::XS;
use IO::File;
use base qw(Exporter);
use open qw(:std :utf8);
use strict;
use utf8;
use vars qw($VERSION %EXPORT_TAGS $TTL_SECONDS $UA $JSON $CSV);

$VERSION = '0.07';

$EXPORT_TAGS{'all'} = [qw(
    mirror_str
    mirror_csv
    mirror_fh
    mirror_file
    mirror_json
    mirror_xml
    mirror_yaml
)];

Exporter::export_ok_tags('all');

=pod

=head1 SYNOPSIS

    use Data::Mirror qw(:all);

    # set the global time-to-live of all cached resources
    $Data::Mirror::TTL = 30;

    # get some data
    $file   = mirror_file($url);
    $string = mirror_str($url);
    $fh     = mirror_fh($url);
    $json   = mirror_json($url);
    $xml    = mirror_xml($url);
    $yaml   = mirror_yaml($url);
    $rows   = mirror_csv($url);

=head1 DESCRIPTION

C<Data::Mirror> tries to take away as much pain as possible when it comes to
retrieving and using remote data sources such as JSON objects, YAML documents,
XML instances and CSV files.

Many Perl programs need to retrieve, store, and then parse remote data
resources. This can result in a lot of repetitive code, to generate a local
filename, check to see if it already exists and is sufficiently fresh, retrieve
a copy of the remote resource if needed, and then parse it. If a program uses
data sources of many different types (say JSON, XML and CSV) then it often does
the same thing over and over again, just using different modules for parsing.

C<Data::Mirror> does all that for you, so you can focus on using the data.

=head1 USAGE

The general form of this module's API is:

    $value = Data::Mirror::mirror_TYPE($url);

where C<TYPE> corresponds to the expected data type of the resource at C<$url>
(which can be a string or a L<URI>).

The return value will be C<undef> if there's an error. The module will C<carp()>
so you can catch any errors.

I<Note: it's possible that the remote resource will actually be someting that
evaluates to C<undef> (for example, a JSON document that is exactly C<"null">,
or a YAML document that is exactly C<"~">), or if there is an error parsing the
resource once retrieved. Consider wrapping the method call in C<eval> if you
need to distinguish between these scenarios.>

By default, if the locally cached version of the resource is younger than
C<$Data::Mirror::TTL_SECONDS> old, C<Data::Mirror> will just use it and won't
try to refresh it, but you can override that per-request by passing the C<$ttl>
argument:

    $value = Data::Mirror::mirror_TYPE($url, $ttl);

=head1 EXPORTS

To import all the functions listed below, include C<:all> in the tags imported
by C<use>:

    use Data::Mirror qw(:all);

You can also import specific functions separately:

    use Data::Mirror qw(mirror_json mirror_csv);

=head1 PACKAGE VARIABLES

=head2 $TTL_SECONDS

This is the global "time to live" of local copies of files, which is used if
the C<$ttl> argument is not passed to a mirror function. By default it's 300
seconds.

If C<Data::Mirror> receives a 304 response from the server, then it will
update the mtime of the local file so that another refresh will not occur
until a further C<$TTL_SECONDS> seconds has elapsed. The mtime will either be
the current timestamp, or the value of the C<Expires> header, whichever is
later.

=cut

#
# global TTL, used if the $ttl method argument to the mirror_* methods isn't
# specified
#
$TTL_SECONDS = 300;

=pod

=head2 $UA

This is an L<LWP::UserAgent> object used to retrieve remote resources. You
may wish to use this variable to configure various aspects of its behaviour,
such as credentials, user agent string, TLS options, etc.

=cut

$UA = LWP::UserAgent->new('agent' => sprintf(
    '%s/%s, LWP::UserAgent %s, Perl %s',
    __PACKAGE__, $VERSION || 'dev',
    $LWP::UserAgent::VERSION,
    $^V,
));

=pod

=head2 $JSON

This is a L<JSON::XS> object used for JSON decoding. You may wish to use this
variable to change how it processes JSON data.

=cut

$JSON = JSON::XS->new->utf8;

=pod

=head2 $CSV

This is a L<Text::CSV_XS> object used for CSV parsing. You may wish to use this
variable to change how it processes CSV data.

=cut

$CSV = Text::CSV_XS->new ({
    'binary' => 1,
});

=pod

=head1 FUNCTIONS

=head2 mirror_file()

This method returns a string containg a name of a local file containing the
resource. All the other functions listed in this section use C<mirror_file()>
under the hood.

C<Data::Mirror> will write local copies of files to the appropriate temporary
directory (determined using C<L<File::Spec>-E<gt>tmpdir>) and tries to reduce
the risk of collision by hashing the URL and the current username. This means
that different programs, run by the same user, that use C<Data::Mirror> to
retrieve the same URL, will effectively share a cache for that URL, but other
users on the system will not. File permissions are set to C<0600> so other
users cannot read the files.

=cut

sub mirror_file {
    my ($url, $ttl) = @_;

    $ttl = $TTL_SECONDS unless (defined($ttl));

    my $file = filename($url);

    return $file unless (stale($url));

    #
    # update the local file
    #
    my $result = $UA->mirror($url, $file);

    if (any { $_ == $result->code } (304, 200)) {
        #
        # if the response had the Expires: header, use that, otherwise use
        # the later of the current mtime or now
        #
        my $expires = str2time($result->header('expires')) || max(stat($file)->mtime, time());

        utime($expires, $expires, $file) if (-e $file);
    }

    carp($result->status_line) if ($result->code >= 400);

    if (-e $file) {
        chmod(0600, $file);
        return $file;
    }

    return undef;
}

=pod

=head2 mirror_str($url)

This method returns a UTF-8 encoded string containing the resource. If it's
possible that the resource might be large enough to use up a lot of memory,
consider using C<mirror_file()> or C<mirror_fh()> instead.

=cut

sub mirror_str {

    my $file = mirror_file(@_);

    if ($file) {
        return encode('UTF-8', read_file($file, 'binmode' => ':utf8'));
    }

    return undef;
}

=pod

=head2 mirror_fh()

This method returns an L<IO::File> handle containing the resource.

=cut

sub mirror_fh {

    my $file = mirror_file(@_);

    if ($file) {
        my $fh = IO::File->new($file);

        $fh->binmode(':utf8');

        return $fh;
    }

    return undef;
}

=pod

=head2 mirror_xml()

This method returns an L<XML::LibXML::Document> handle containing the resource.

=cut

sub mirror_xml {

    my $file = mirror_file(@_);

    return XML::LibXML->load_xml('location' => $file) if ($file);

    return undef;
}

=pod

=head2 mirror_json()

This method returns a JSON data structure containing the resource. This could be
C<undef>, a simple string, or an arrayref or hashref.

=cut

sub mirror_json {

    my $str = mirror_str(@_);

    return $JSON->decode($str) if ($str);

    return undef;
}

=pod

=head2 mirror_yaml()

This method returns a YAML data structure containing the resource. This could be
C<undef>, a simple string, or an arrayref or hashref.

=cut

sub mirror_yaml {

    my $file = mirror_file(@_);

    return YAML::XS::LoadFile($file) if ($file);

    return undef;
}

=pod

=head2 mirror_csv()

This method returns a reference to an array of arrayrefs containing the CSV rows
in the resource.

=cut

sub mirror_csv {

    my $fh = mirror_fh(@_);

    if ($fh) {
        my @rows;

        while (my $row = $CSV->getline($fh)) {
            push(@rows, $row);
        }

        $fh->close;

        return \@rows;
    }

    return undef;
}

=pod

=head1 OTHER FUNCTIONS

    $file = Data::Mirror::filename($url);

Returns the local filename that L<Data::Mirror> would use for the given URL.

=cut

sub filename {
    my $url = shift;

    #
    # the local filename is based on the hash of the URL, salted by the user's
    # login
    #
    return File::Spec->catfile(
        File::Spec->tmpdir,
        join('.', (
            __PACKAGE__,
            sha256_hex(
                getlogin(),
                ':',
                ($url->isa('URI') ? $url->canonical->as_string : $url),
            ),
            'dat'
        ))
    );
}

=pod

    $exists = Data::Mirror::mirrored($url);

Returns true if a copy of the resource identified by C<$url> exists locally.
This function is equivalent to running C<-e Data::Mirror-E<gt>filename($url)>.

=cut

sub mirrored { -e filename(@_) }

=pod

    $stale = Data::Mirror::stale($url, $ttl);

Returns true if the resource identified by C<$url> (a) does not exist locally or
(b) its modification time is more then C<$ttl> seconds in the past. If C<$ttl>
is not specified then C<$Data::Mirror::TTL_SECONDS> will be used instead.

=cut

sub stale {
    my ($url, $ttl) = @_;

    my $file = filename($url);

    return 1 unless (-e $file);

    return 1 unless stat($file)->mtime > time() - ($ttl || $TTL_SECONDS);

    return undef;
}

=pod

=head1 REPORTING BUGS, CONTRIBUTING ENHANCEMENTS

This module is developed on GitHub at L<https://github.com/gbxyz/perl-data-mirror>.

=cut

1;
