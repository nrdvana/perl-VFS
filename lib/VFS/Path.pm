package VFS::Path;
use strict;
use warnings;
use constant {
   _FS => 0,
   _STAT => 1,
   _LSTAT => 2,
   _FIELDS => 3,
   _VOLUME => 4,
   _PATH_BASE => 5,
   NATIVE_PATH_SEP => ($^O eq 'MSWin32'? "\\", '/'),
};
use overload
   '""' => \&to_bytes,
   '-X' => \&_filetest;

=head1 DESCRIPTION

The VFS::Path object represents an I<absolute> path within a known L<VFS::FileSystem>.
The path object holds a strong reference to the filesystem, and after creating the path object
it is unaffected by changes to the current working directory or current volume.  However, the
path is not I<resolved> at creation time, so it could point to a nonexistent directory or file.

Path objects are created via L<VFS::FileSystem/path> method, or by the global function
L<VFS/path> which is just a shortcut to call C<< $VFS::root->path(...) >>.

Path objects hold a cache of the results of "stat" and "lstat", which is refreshed each time
you call the L</stat> or L</lstat> method.  If you want to use the cache, use the attributes of
the Path object rather than accessing C<< ->stat->$attribute >>.

=head1 UNICODE SUPPORT

All native Perl file routines (and even CPAN modules) expect paths to be composed of bytes, and
flatten unicode to UTF-8.  Perl also has a requirement that you never mix Unicode and bytes in
the same string (such as appending unicode to a utf-8 representation of unicode, or vice-versa)
or else you end up with garbage.  This makes Unicode file names in Perl cumbersome, because you
must first encode all unicode strings as UTF-8 bytes before concatenating them.  Most perl
modules do not help you with this because it is impossible to know whether characters in the
range C<< (0x80 - 0xFF) >> were intended as unicode characters or bytes; the developer is
responsible for keeping those straight.

While adhering to those rules is the only way to get a 100% correct perl program, the situation
is far from ideal; programmers expect to be able to pass around Unicode as file names,
especially in a scripting language designed for convenience.  So, this module has some special
support for common cases.

=head2 Stringification

First, any time you perform automatic stringification or call L</path_bytes> on a Path
object, it returns the bytes that you would need to pass to Perl's file functions like C<open>
or C<opendir>.  For most environments, this means returning UTF-8 encoding, with '/' separators
on Unix and "\\" separators on Windows.

If you want the unicode view of a path, use L</path_str>.

L</basename> and L</dirname> always return Unicode.

L</basename_native> and L</dirname_native> always return platform encoding, e.g. UTF-8 bytes.

Regular expressions supplied to filters will operate on the Unicode view of the path.

=head2 Creation

Any time a path is created from data read from the filesystem, it will use its knowledge of the
filesystem and platform to correctly interpret the bytes or characters.

Any time a path is created from Perl strings, it uses a hieuristic.  For each component between
path separators, if the component contains characters above 0x00FF, the component is treated as
unicode.  Else if the component contains charachers in the range C<< (0x80 .. 0xFF) >> it
checks whether they are a valid encoding of the program's current locale, and if so assumes
they are unicode that was already encoded.  If it is not valid UTF-8, the bytes are preserved
as-is.

The cases where this hieuristic could fail are:

=over

=item *

A user is running perl in a UTF-8 locale and wanted a Latin-1 character in the (0x80-0xFF)
range written to a filename as a byte rather than as a UTF-8 sequence.  (they will get a
UTF-8 sequence)

=item *

A user is running perl in a non-UTF-8 locale and tried passing a UTF-8 encoded string to this
module, expecting it to treat those as unicode characters.  (each byte becomes a character)

=item *

A user is running perl in a UTF-8 locale and pass a sequence of Unicode characters which happen
to look like a valid UTF-8 bytes.

=back

If you are worried about these cases, use the L<VFS/path_bytes> function or
L<VFS::FileSystem/path_bytes> method and make sure to provide correct platform encodings of
characters to these functions.  It will throw an exception if your strings contain codepoints
above 0xFF.

=head1 PATH ATTRIBUTE METHODS

=head2 fs

Return the reference to the L<VFS::FileSystem> this path came from.

=head2 path_str

Return the path as a unicode string.

=head2 path_bytes

Return the path encoded as bytes for the platform's filesystem calls.

=head2 uri

Return a URI::file instance for this path.

=cut

sub fs { $_[0][_FS] }

sub path_bytes {
   VFS::_str_to_platform_bytes($_[0]->path_str);
}
sub path_str   { join(NATIVE_PATH_SEP, @{$_[0]}[_VOLUME .. $#{$_[0]}])
sub uri {
   my @parts= @{$_[0]}[_VOLUME .. $#{$_[0]}];
   for (@parts) {
      utf8::encode($_);
      $_ =~ s/([^-A-Za-z0-9_.!~*'()])/'%'.sprintf("%02X", ord $1)/ge
   }
   URI->new(join('/', 'file:/', @parts));
}

=head1 FILE INSPECTION METHODS

The following methods look up the path in the filesystem.  For each, if the filesystem calls
fail, the function will return C<undef> and set C<$!>, if called in list or scalar context.
If you call them in void context (i.e. not checking the return value) they will C<die> on
failure, in addition to setting C<$!>.

Additional information about failures may be found from C<< $path->fs->last_error >>, which
will return an object describing the error more completely.

=head2 stat

Call stat() on the path, returning an object compatible with L<File::stat>.

This updates the cached stat for the path object.

=head2 lstat

Like C<stat>, but returns information about a symlink entry rather than the file it links to.
If the path does in fact refer to a link, the C<lstat> result is cached separately from the
C<stat> result, else the cached C<stat> is also updated.

=head2 -X

Like a File::stat object, this Path object can be used for all the usual tests like "-x" and
"-e" and "-s".  These operations uses the cached most recent call to C<stat>, except for
"-l" which uses the most recent cached value of L</lstat>.

=cut

sub stat { $_[0][_STAT]= $_[0][_FS]->stat($_[0]) }
sub lstat {
   $_[0][_LSTAT]= $_[0][_FS]->lstat($_[0]);
   $_[0][_STAT]= $_[0][_LSTAT] unless -l $_[0][_LSTAT];
}

# Receives overload '-X'
sub _filetest {
   my ($self, $op)= @_;
   my $stat= $op eq 'l'? ($_[0][_LSTAT] ||= $_[0][_FS]->lstat($_[0]))
      : ($_[0][_STAT] ||= $_[0][_FS]->stat($_[0]));
   return $stat? $stat->_filetest($op)
      : $op eq 'e'? 0 # -e test returns false, not undef
      : undef;
}

=head2 exists

Returns true if 'stat' succeeds.

=head2 is_dir

Returns true if 'stat' refers to a directory.

=cut

sub exists { _filetest($_[0], 'e') }
sub is_dir { _filetest($_[0], 'd') }

=head2 size

Return file size in bytes, same as "-s".  Returns undef if the file does not exist or if it is
a dangling symlink.

=head2 size_text, size_text_XB, size_text_XiB

  my $text= $path->size_text($digits = 2);
  my $text= $path->size_text_XB($digits = 2);
  my $text= $path->size_text_XiB($digits = 2);

Return file size as a human-readable string.  C<$digits> is the minimum number of significant
digits to include if the number of bytes includes a decimal point.

Example:

  # 12345
  size_text(2);     # "12 K"
  size_text_XB(4);  # "12.34 kB" or "12,34 kB" depending on locale
  size_text_XiB(3); # "12.1 KiB" or "12,1 KiB" depending on locale
  # 1000000
  size_text(1);     # "977 K"
  size_text_XB(1);  # 1 MB
  size_text_XiB(1); # "977 KiB"

=cut

sub size { _filetest($_[0], 's') }

my @_non_si_suffix= qw( B K M G T P E Z Y R Q );
my @_si_suffix=     qw( B kB MB GB TB PB EB ZB YB RB QB );
my @_si_iB_suffix=  qw( B KiB MiB TiB PiB EiB ZiB YiB RiB QiB );
sub _size_text {
   my ($self, $digits, $mod, $suffix)= @_;
   $digits= 2 unless defined $digits;
   my $s= $self->size;
   return '' unless defined $s;
   my $pow= 0;
   ++$pow, $size /= $mod while $size > $mod && $pow < $#$suffix;
   my $precision= $digits - length(int(.5+$size));
   sprintf("%.*f %s", $size, $precision < 0? 0 : $precision, $suffix->[$pow]);
}

sub size_text     { _size_text($_[0], $_[1], 1024, \@_non_si_suffix) }
sub size_text_XB  { _size_text($_[0], $_[1], 1000, \@_si_suffix) }
sub size_text_XiB { _size_text($_[0], $_[1], 1024, \@_si_iB_suffix) }

=head1 DIRECTORY WALKING METHODS

=head2 resolve

Consult the filesystem and check each component of the path for symlinks, resolving them to
the real underlying directory.  Returns a new path object.

Aliases: realpath

=cut

sub resolve { $_[0][_FS]->resolve($_[0]) }
sub realpath { shift->resolve(@_) }

=head2 find

  my $pathset = $path->find( %filter );
  my $i= $pathset->iter;
  while (my $f= &$i) {
    ...
  }

Return a L<VFS::PathSet> object representing the set of all paths under this path, filtered by
the C<%filter>, if any.  See L<VFS::PathSet/filter> for the possible options.

=head2 iter

  $iter= $path->iter;

Shortcut for C<< $path->find(maxdepth => 1)->iter >>.  This is equivalent to the list returned
by 'children', but as an iterator.

=head2 children

  @paths= $path->children;
  @paths= $path->children($name_regex);

Returns all immediate files and directories of the given C<$path>, but excluding '.' and '..'
entries.  If C<$name_regex> is given, it is used as a filter.  (it only applies to the final
name component of entries, i.e. the string listed in the directory)

=cut

sub find { $_[0][_FS]->new_fileset(@_) }

sub iter { splice(@_, 1, 0, maxdepth => 1); $_[0][_FS]->new_fileset(@_)->iter }

sub children {
   @{ $_[0][_FS]->new_fileset(maxdepth => 1, (name => $_[1])x(defined $_[1]))->all }
}

1;
