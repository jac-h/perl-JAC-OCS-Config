package JAC::OCS::Config::Header;

=head1 NAME

JAC::OCS::Config::Header - Parse and modify OCS HEADER configurations

=head1 SYNOPSIS

  use JAC::OCS::Config::Header;

  $cfg = new JAC::OCS::Config::Header( File => 'header.ent');

=head1 DESCRIPTION

This class can be used to parse and modify the header configuration
information present in the HEADER_CONFIG element of an OCS configuration.

=cut

use 5.006;
use strict;
use Carp;
use warnings;
use XML::LibXML;

use JAC::OCS::Config::Error qw| :try |;

use JAC::OCS::Config::XMLHelper qw(
                                    find_children
                                    find_attr
                                    indent_xml_string
                                 );

use JAC::OCS::Config::Header::Item;

use warnings::register;
use base qw/ JAC::OCS::Config::CfgBase /;

use vars qw/ $VERSION /;

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);

=head1 METHODS

=head2 Constructor

=over 4

=item B<new>

Create a new HEADER configuration object. An object can be created from
a file name on disk, a chunk of XML in a string or a previously created
DOM tree generated by C<XML::LibXML> (i.e. A C<XML::LibXML::Element>).

  $cfg = new JAC::OCS::Config::Header( File => $file );
  $cfg = new JAC::OCS::Config::Header( XML => $xml );
  $cfg = new JAC::OCS::Config::Header( DOM => $dom );

The method will die if no arguments are supplied.

=cut

sub new {
  my $self = shift;

  # Now call base class with all the supplied options +
  # extra initialiser
  return $self->SUPER::new( @_,
                            $JAC::OCS::Config::CfgBase::INITKEY => {
                                                                    ITEMS => [],
                                                                   }
                          );
}

=back

=head2 Accessor Methods

=over 4

=item B<items>

Header items found in this configuration, in the order in which they
appear in the config file.

  @i = $h->items;
  $h->items( @i );

=cut

sub items {
  my $self = shift;
  if (@_) {
    @{$self->{ITEMS}} = @_;
  }
  return @{$self->{ITEMS}};
}

=item B<nitems>

Return the number of items in the header.

=cut

sub nitems {
  my $self = shift;
  return ( $#{$self->{ITEMS}} + 1 );
}

=item B<item>

Retrieve a specific Item object by index (if the argument looks like
an integer), by keyword, by keyword pattern (if qr// object) or by
code reference.

 $item = $hdr->item( 5 );
 $item = $hdr->item( 'PROJECT' );
 @items = $hdr->item( 'COMMENT' );
 @items = $hdr->item( qr/CRVAL/ );

If a code reference is specified, it will be called once for
each item (with the item passed in as argument) and should return true or false
depending on whether the item matches.

 @items = $hdr->item( sub { $_[0]->method eq 'TRANSLATOR' } );

In list context returns an empty list if no match. In scalar context
returns the matching item, undef if no matches, or the first matching
item. In most cases only one item will match in the header. HISTORY
and COMMENT are the most common multiple matches.

If an index is specified the array items start counting at 0.

=cut

sub item {
  my $self = shift;
  my $arg = shift;
  return () unless defined $arg;

  if ($arg =~ /^[0-9]+$/) {
    if ($arg > -1 && $arg < $self->nitems) {
      my @items = $self->items;
      return $items[$arg];
    } else {
      return ();
    }
  } else {
    # String or regexp match
    my @items = $self->items;

    my @match;
    if (ref($arg) eq 'Regexp' ) {
      @match = grep { $_->keyword =~ $arg } @items;
    } elsif (ref($arg) eq 'CODE') {
      @match = grep { $arg->( $_ ) } @items;
    } else {
      @match = grep {
        defined $_->keyword &&
        $_->keyword eq $arg } @items;
    }

    return (wantarray ? @match : $match[0] );
  }
}


=item B<set_ocscfg_filename>

This method locates the special callback hint in the header
XML (getOCSCFG) or the FITS header OCSCFG itself, and forces the
value to be the supplied filename.

  $hdr->set_ocscfg_filename( $filename );

Usually called just before the file is written to disk.

=cut

sub set_ocscfg_filename {
  my $self = shift;
  my $filename = shift;
  my $magic = 'OCSCFG';

  # Looking either for keyword of OCSCFG or method getOCSFG
  my @items = $self->item( sub {
                             (defined $_[0]->keyword &&
                              $_[0]->keyword eq $magic) ||
                               (defined $_[0]->method &&
                                $_[0]->method eq "get$magic");
                           } );

  for my $i (@items) {
    $i->value( $filename );
    $i->source( undef );        # clear derived status
  }

}

=item B<stringify>

Create XML representation of object.

=cut

sub stringify {
  my $self = shift;
  my %args = @_;

  my $xml = '';

  $xml .= "<". $self->getRootElementName . ">\n";

  # Version declaration
  $xml .= $self->_introductory_xml();

  for my $i ($self->items) {

    $xml .= "$i";

  }

  $xml .= "</". $self->getRootElementName .">\n";
  return ($args{NOINDENT} ? $xml : indent_xml_string( $xml ));
}

=item B<read_source_definitions>

It is possible for source definitions (eg DERIVED, DRAMA, RTS_STATE etc)
to be specified in a separate text file indexed by keyword. If this
method is called the supplied text file will be read and the source
definitions will be updated in the current header. Only keywords present in
the current header will be modified.

If a header item already has source information it will be overridden.

  $hdr->read_source_definitions( $defn_file );

The format of the file is defined in section L</SOURCE DEFINITIONS>.

=cut

sub read_source_definitions {
  my $self = shift;
  my $file = shift;

  # Get a hash with all the heavy lifting performed
  # indexed by KEYWORD
  my %modifiers = $self->_read_source_defs( $file );

  # Since there is no hash table lookup into the array of items
  # (unlike Astro::FITS::HdrTrans) it is more efficient to
  # go through each item in turn and see if there is a modified
  # specified for it.
  for my $i ($self->items) {
    my $k = $i->keyword;
    next unless defined $k; # BLANKFIELD, COMMENT
    if (exists $modifiers{$k}) {
      # special case an undef entry
      if (!defined $modifiers{$k}) {
        $i->unset_source;
      } else {
        # get the new information and obtain the source type
        my %updated_info = %{$modifiers{$k}};
        my $source = $updated_info{SOURCE};
        delete $updated_info{SOURCE}; # even though it will be ignored by set_source

        # now update the Item
        $i->set_source( $source, %updated_info );

        # update comment if one is given
        $i->comment( $updated_info{COMMENT} ) if exists $updated_info{COMMENT};

      }
    }
  }

  return;
}

=item B<read_header_exclusion_file>

Read the header exclusion file and return an array of all headers that
should be excluded.  Returns empty list if the file can not be found.

  @toexclude = $hdr->read_header_exclusion_file($file);

It takes two optional arguments: a truth value to indicate to print
messages at all; and an output handle to which to print verbose
messages.  If no output handle is defined, then currently selected
handle is used.

  @toexclude = $hdr->read_header_exclusion_file($file, my $verbose = 1, \*STDERR );

=cut

sub read_header_exclusion_file {

  my $self = shift;
  my ( $xfile, $verbose, $outh ) = @_;

  return unless -e $xfile;

  $verbose
    and __PACKAGE__->_print_fh( "Processing header exclusion file '$xfile'.\n", $outh );

  # Get the directory path for INCLUDE handling
  my ($vol, $rootdir, $barefile) = File::Spec->splitpath( $xfile );

  # this exclusion file has header cards that should be undeffed
  open my $fh, '<', $xfile
    or throw OMP::Error::FatalError("Error opening exclusion file '$xfile': $!");

  # use a hash to make it easy to remove entries
  my %toexclude;
  while (defined (my $line = <$fh>)) {

    for ( $line ) {

      # remove comments
      s/#.*//;
      # and trailing/leading whitespace
      s/^\s+//;
      s/\s+$//;
    }

    next unless $line =~ /\w/;

    # A "+" indicates that the keyword should be removed from toexclude
    my $addback = 0;
    if ($line =~ /^\+/) {

      $addback = 1;
      $line =~ s/^\+//;
    }

    # Keys that are associated with this line
    my @newkeys;

    # INCLUDE directive
    if ($line =~ /^INCLUDE\s+(.*)$/) {

      my $fullpath = File::Spec->catpath( $vol, $rootdir, $1 );
      push(@newkeys, $self->read_header_exclusion_file( $fullpath ) );
    } else {

      push(@newkeys, $line);
    }

    if ($addback) {

      delete $toexclude{$_} for @newkeys;
    } else {

      # put them on the list of keys to remove
      $toexclude{$_}++ for @newkeys;
    }

  }

  return sort keys %toexclude;
}

=item B<remove_excluded_headers>

Removes the excluded headers (from a C<JAC::OCS::Config::Header>
object) given in an array reference.

  $hdr->remove_excluded_headers( [ 'header_A', 'header_B' ] );

It takes two optional arguments: a truth value to indicat to print
messages at all; and an output handle to which to print verbose
messages.  If no output handle is defined, then currently selected
handle is used.

  #  Print messages.
  $hdr->remove_excluded_headers( $array_ref, 1 );

  #  Print messages to standard error.
  $hdr->remove_excluded_headers( $array_ref, 1, \*STDERR );

=cut

sub remove_excluded_headers {

  my ( $self, $toexclude, $verbose, $outh ) = @_;

  # Message formats.
  my $found = "\tClearing header %s\n";
  my $invisible = "\tAsked to exclude header card '%s' but it is not part of the header\n";

  for my $ex ( @{ $toexclude } ) {

    my $item = $self->item( $ex );
    if ( defined $item ) {

      $verbose and __PACKAGE__->_print_fh( sprintf( $found, $ex ), $outh );
      $item->undefine;
    }
    else {

      $verbose and __PACKAGE__->_print_fh( sprintf( $invisible, $ex ), $outh );
    }
  }

  return;
}

=item B<verify_header_types>

Returns a truth value to indicate successful verification, given an
C<Astro::FITS::Header> object.

L<Astro::FITS::Header> types are compared against the header
specification, assuming header exclusion has already taken place (see
I<read_header_exclusion_file> and I<remove_excluded_headers> methods).

  $hdr->verify_header_types( $fits );

Throws I<JAC::OCS::Config::Error> exception if any of the header types cannot be
verified.

=cut

sub verify_header_types {

  my ( $self, $fits ) = @_;

  throw JAC::OCS::Config::Error "No Astro::FITS::Header obeject given."
    unless $fits && ref $fits
        && $fits->isa( 'Astro::FITS::Header' );

  my ( %err );
  for my $ocs_h ( $self->items ) {

    my $name = $ocs_h->keyword;

    #  In case of 'BLANKFIELD' or 'COMMENT' types (see
    #  /jac_sw/hlsroot/scuba2_wireDir/header/scuba2/scuba2.ent).
    next unless defined $name;

    my $expected = uc $ocs_h->type;

    for my $fh ( $fits->itembyname( $name ) ) {

      my $actual = uc $fh->type;
      next if $expected eq $actual;

      $err{ $name } = { 'expected' => $expected, 'actual' => $actual };
    }
  }

  my $err = '';
  for ( sort keys %err ) {

    $err .= sprintf "For header '%s', type expected '%s' but found '%s'.\n",
              $_, $err{ $_ }->{'expected'}, $err{ $_ }->{'actual'}
  }
  throw JAC::OCS::Config::Error $err if $err;

  return;
}

=back

=head2 Class Methods

=over 4

=item B<getRootElementName>

Return the name of the _CONFIG element that should be the root
node of the XML tree corresponding to the Header config.

 @names = $h->getRootElementName;

=cut

sub getRootElementName {
  return( "HEADER_CONFIG" );
}

=back

=begin __PRIVATE_METHODS__

=head2 Private Methods

=over 4

=item B<_process_dom>

Using the C<_rootnode> node referring to the top of the Header XML,
process the DOM tree and extract all the coordinate information.

 $self->_process_dom;

Populates the object with the extracted results.

A source definition file will be read automatically if the XML contains
a C<SOURCE_DEFINITION> element with attribute FILE pointing to a
definition file.

=cut

sub _process_dom {
  my $self = shift;

  # Find all the header items, including dummy INCLUDE headers
  # that will be removed.
  my $el = $self->_rootnode;
  my @items = find_children( $el, qr/^(SUBHEADER|HEADER|HEADER_INCLUDE)/, min => 1 );

  my @obj;
  for my $a (@items) {
    my $name = $a->nodeName;
    my @subitems;
    if ($name =~ /_INCLUDE/) {
      @subitems = find_children( $a, qr/^(SUB)?HEADER/, min => 1 );
    } elsif ($name eq 'HEADER' || $name eq 'SUBHEADER') {
      @subitems = ($a);
    } else {
      throw JAC::OCS::Config::Error::FatalError("Odd internal error in HEADER_CONFIG parse");
    }

    my $ItemClass = "JAC::OCS::Config::Header::Item";
    for my $i (@subitems) {
      my %attr = find_attr( $i, "TYPE","KEYWORD","COMMENT","VALUE");
      $attr{is_sub_header} = ($i->nodeName =~ /^SUB/ ? 1 : 0);

      # Look for source information - there should only be one match
      my %mon;
      for my $s ($ItemClass->source_types) {
        my @found = find_children($i,
                                  $ItemClass->source_pattern($s),
                                  min => 0, max => 1);
        if (@found) {
          %mon = find_attr($found[0],$ItemClass->source_attrs($s));
          $mon{SOURCE} = $s;
          last;
        }
      }

      # Now create object representation
      push(@obj, new JAC::OCS::Config::Header::Item(
                                                    %attr,
                                                    %mon,
                                                   ));
    }
  }

  $self->items( @obj );

  # update the definitions if required
  my $defn = find_children( $el, "SOURCE_DEFINITION", min => 0, max => 1 );
  if ($defn) {
    my $file = find_attr($defn, "FILE");
    $self->read_source_definitions( $file ) if defined $file;
  }

  return;
}

=item B<_read_source_defs>

Read a source definition file and return a hash indexed by keyword.

 %modified = $self->_read_source_defs( $file );

To support recursion a task mapping hash can be supplied as a second
argument.

 %modified = $self->_read_source_defs( $file, \%taskmap );

There is usually no need to specify this explicitly.

=cut

sub _read_source_defs {
  my $self = shift;
  my $file = shift;
  my $taskmap = shift;

  throw JAC::OCS::Config::Error::BadArgs( "Must supply a definition file name" )
    unless $file;

  # Assume current directory
  open(my $fh, "<", $file)
    or JAC::OCS::Config::Error::IOError->throw("Could not open file '$file': $!");

  my @lines = <$fh>;
  close($fh) or
    JAC::OCS::Config::Error::IOError->throw("Error closing file '$file': $!" );
  chomp(@lines);

  return $self->_parse_source_defs( \@lines, $taskmap );
}

=item B<_parse_source_defs>

Given lines of content read from a definition file, parse it and
return a hash indexed by keyword.

  %modified = $self->_parse_source_defs( \@lines );

=cut

sub _parse_source_defs {
  my $self = shift;
  my $lref = shift;
  my $tmref = shift;

  # local copy of task mappings to prevent mappings propagating
  # upwards.
  my %taskmap;
  %taskmap = %$tmref if defined $tmref;

  my %modifiers;
  for my $l (@$lref) {
    $l =~ s/\#.*//;     # strip comments
    $l =~ s/^\s*//;     # strip leading space
    $l =~ s/\s*$//;     # strip trailing space
    next unless $l =~ /\w/;

    # remove xml-isms since they do not add information
    $l =~ s/<//;
    $l =~ s/\/>//;

    # split on whitespace (we assume the key=val pairs do not
    # include whitespace)
    my @parts = split(/\s+/, $l );

    # The first part of the line is the command
    my $command = uc(shift(@parts));

    if ($command eq 'INCLUDE') {
      my $file = shift(@parts);
      # do not trap infinite recursion
      my %submod = $self->_read_source_defs( $file, \%taskmap );

      # merge with current modifiers - precedence to included data
      %modifiers = (%modifiers, %submod);

    } elsif ($command eq 'TASKMAP') {
      if (@parts >= 2) {
        my $generic = shift(@parts);
        my $specific = shift(@parts);
        $taskmap{$generic} = $specific;
      } else {
        warnings::warnif( "TASKMAP requires two values, not ".@parts );
      }

    } elsif (@parts == 1 && $parts[0] eq 'UNDEF') {
      # special case a request to remove all source information from keyword
      $modifiers{$command} = undef;

    } else {

      # must be a SOURCE and one attribute
      JAC::OCS::Config::Error::XMLBadStructure->throw("Unrecognized format for line '$l'")
          unless @parts > 1;

      my $keyword = $command;

      my %item;

      # SOURCE can be in XML or internal form
      my $source = JAC::OCS::Config::Header::Item->normalize_source(shift(@parts));
      $item{SOURCE} = $source;

      # Now process the keyword=val pairs
      while (my $part = shift(@parts)) {
        if ($part =~ /=/) {
          my ($key, $value) = split(/=/, $part, 2);
          $key = uc($key);
          $value =~ s/\"//g; # strip quotes
          $item{$key} = $value;
        } else {
          # end of key=val section so must be comment override
          # Put comment back together and abort loop
          $item{COMMENT} = join(" ", $part, @parts);
          last;
        }
      }

      # Apply task mapping
      if (($item{SOURCE} eq 'DERIVED' ||
           $item{SOURCE} eq 'DRAMA' ) && exists $taskmap{$item{TASK}}) {
        $item{TASK} = $taskmap{$item{TASK}};
      }

      # store the information
      $modifiers{$keyword} = \%item;

    }

  }

  return %modifiers;
}

=item B<_print_fh>

Prints a message to a file handle if the message is defined.  File
handle is optional; if not given, then message is printed to the
currently selected file handle.

  JAC::OCS::Config::Header->_print_fh( 'some message' );

  #  Send message to standard error.
  JAC::OCS::Config::Header->_print_fh( 'some message', \*STDERR );

=cut

sub _print_fh {

  my ( $self, $msg, $fh ) = @_;

  return unless defined $msg ;

  $fh = defined $fh ? $fh : select;
  print $fh $msg;
  return;
}

=back

=end __PRIVATE_METHODS__

=head1 SOURCE DEFINITIONS

The source definitions file has the following format:

=over 4

=item Comment character

The comment character is "#".

=item INCLUDE filename

Used to include definitions from another file. Usually used to
load shared definitions. Any definitions previously read will be
overridden if the same definitions exist in this file. The position
of the INCLUDE (at the start or end of the keywords) controls the
precedence behaviour.

=item TASKMAP Generic Specific

For DERIVED source definitions, this line can be used to set up
a mapping from a generic task name to a specific task name (since
task names may differ between instruments). The task map is case
sensitive. Task mappings defined in a file are used in INCLUDEd
files that have been read after the mapping is defined. A taskmap
defined in an included file does not affect the definitions in the
parent file.

=item KEYWORD <DERIVED TASK="task" EVENT="stop" /> Comment

All other lines are assumed to be keyword definitions and the
first word will be treated as a KEYWORD. The XML syntax is optional
and

   KEYWORD DERIVED TASK=X EVENT=Y Comment

is also supported. Any text at the end that is not Keyword=Value
will be treated as a comment that will be inserted into the header.
This is used if an instrument requires a slightly different comment
to appear in a file.

=item KEYWORD UNDEF

If the source identifier is explicitly UNDEF (rather than DRAMA, DERIVED
etc) the source definition for this keyword will be removed.

=back

=head1 XML SPECIFICATION

The Header XML configuration specification is documented in OCS/ICD/011
with a DTD available at
http://docs.jach.hawaii.edu/JCMT/OCS/ICD/011/headers.dtd.

=head1 SEE ALSO

L<JAC::OCS::Config>, L<Astro::FITS::Header>.

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

Copyright (C) 2008 Science and Technology Facilities Council.
Copyright 2004-2007 Particle Physics and Astronomy Research Council.
All Rights Reserved.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful,but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program; if not, write to the Free Software Foundation, Inc., 59 Temple
Place,Suite 330, Boston, MA  02111-1307, USA

=cut

1;
