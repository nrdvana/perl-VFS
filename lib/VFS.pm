package VFS;
use v5.18;
use Exporter::Extensible -exporter_setup => 1;
use Carp;
use VFS::FileSystem::PerlIO;

our $VERSION= 0; #VERSION
#ABSTRACT: Virtual Filesystem for Perl

=head1 SYNOPSIS

Use the global VFS in place of Path::Class or Path::Tiny:

  use VFS 'path';
  say path(".")->resolve;
  
  VFS::mount(bind => '/srv/data', './data') or die $@;
  say join "\n", path("./data")->children->@*;
  
  VFS::mount(GIT => { git_dir => '.git' }, '.git') or die $@;
  say path(".git/branch/main/README.md")->slurp;
  
  VFS::mount(SFTP => { user => 'x', pass => 'REDACTED' }, '/mnt/sftp') or die $@;
  say path("/mnt/sftp/incoming/some_data.csv")->slurp;

Change mounts without changing your script:

  perl -MVFS=/path/to/config.json myscript.pl
  # or
  export PERL5OPT=-MVFS=/path/to/config.json
  ./myscript.pl

Replace all Perl IO (C<readdir>, C<open>, etc) with the virtual FS:

  perl -MVFS=-override_core ./myscript.pl

=head1 FEATURES

There are L<other virtual filesystem modules on CPAN|/SEE ALSO>, but this one features:

=over

=item Browse Real Files By Default

In addition to being an API for object-oriented virtual filesystems, this module collection is
also intended to be a "daily driver" for file access, like L<Path::Class> or L<Path::Tiny>.

=item Override PerlIO

This module lets you specify a virtual fs to handle all the CORE:: functions that operate on
paths, enabling all your perl modules to access the virtual files.

=item Unicode-Aware

On Win32, paths are natively Unicode.  On Linux, you can enable (or disable) interpretation
of paths according to Locale.  The end result is that the L<VFS::Path> object lets you use
unicode strings to browse directories and open files, which is an improvement over
L<Path::Class> or L<Path::Tiny> or the native Perl IO functions.

=item Cross-Platform

This module permits each filesystem to have the concept of "Volumes", and interpret their own
path strings, allowing this to seamlessly integrate with Windows.

=item Configurability

You can specify filesystems in a config file, rather than setting them up in code, and you can
specify this in PERL5OPT environment so that the scripts don't need to be aware of it ahead of
time.

=back

=head1 DESCRIPTION

This package collection gives you the ability to build and use virtual filesystems, with
plugins to support back-ends like zip files, git object trees, SFTP / HTTP servers, etc.
In short, it lets you do the kinds of things a Linux FUSE module would let you do, but
cross-platform, and without root access to the host.

The L<VFS::FileSystem> object provides object-oriented access to filesystem instances.  The
global variable C<$VFS::root> provides a default filesystem for function-access.  Bold users
who like to live dangerously may also use the "-override_core" option to intercept all of
Perl's core filesystem functions (but you must load VFS before all other modules for that to
work)

The structure of the VFS can be loaded from a config file, but no config file is loaded by
default.  This can be specified on the commandline or PERL5OPT environment variable:

  export PERL5OPT=-MVFS=/path/to/config.json

You could also configure it programmatically in C<< $Config{sitelib}/sitecustomize.pl >> if
that feature is enabled for your installed perl.  Note that mount points are loaded lazily, so
if you configure a bunch of SFTP sites it won't immediately try connecting to them at startup.

=head1 MEET THE OBJECTS

=over

=item L<VFS::FileSystem>

This represents a virtual filesystem, composed of named volumes at the root, each with a file
tree under it.  Filesystems may be mounted at any path within another filesystem.

=item L<VFS::Path>

Filesystems return these objects to represent unopened files.  A filesystem will always allow
generic "component" paths (a list of directory names ending with file name) but may also allow
other types of path objects depending on what is available from the back-end.  Paths hold a
strong reference to the originating filesystem.  Path objects may refer to nonexistent paths
in the filesystem.

=item L<VFS::File>

This represents an open file, and will be a blessed GLOB ref which also descends from IO::File,
for maximum compatibility.  Files hold a strong reference to the originating filesystem.

=back

=head1 EXPORTS

All L<functions|/FUNCTIONS> may be exported.  The following additional features can be
requested from the C<< use VFS ... >> line:

=over

=item C<< -config => $filename_or_data >>

This is a shorthand to calling L<VFS::configure|/configure> at module-load time.

=item C<< /conf >>, C<< ./conf >>, C<< ~/conf >>, C<< C:\conf >>

Any option starting with C<< qr{ [^.~] / }x >> or, on Win32, C<< qr{ (?: [A-Z] : )? \\ }x >>
will automatically be treated as the filename for the C<-config> option.

=item C<< -override_core >>

This requests VFS to intercept all CORE:: filesystem functions and make them read and write
through the configured virtual filesystem.  This is only possible very early in startup before
other modules have been loaded.  Also, it won't affect C-library functions.

=back

=cut

sub import {
	# Special case: if first non-ref argument looks like a file path,
	# treat it as a -config option.
	my $first_nonref= 1;
	++$first_nonref while ref $_[$first_nonref];
	if ($first_nonref <= $#_ && $_[$first_nonref] =~ m{ ^ ( [.~] | [A-Za-z]: )? [/\\] }x) {
		splice(@_, $first_nonref, 0, '-config');
	}
	goto \&Exporter::Extensible::import;
}

=head1 FUNCTIONS

=head2 root

This returns the root VFS::FileSystem object.  It is nothing more than a read-accesor for
C<$VFS::filesystem{root}>.  You may change the root by setting or localizing that variable.

The initial value for C<root> is a clone of L</real>.

=head2 real

This returns a VFS::FileSystem that reads the real filesystem perl is running in.  It is a
read-accessor for C<$VFS::filesystem{real}>. You should probably not change that variable.

=cut

our $real= VFS::FileSystem::PerlIO->new;
sub real { $real }

our $root= $real->clone;
sub root { $root }

our %filesystem;
require Hash::Util;
Hash::Util::hv_store(%filesystem, 'root', $root);
Hash::Util::hv_store(%filesystem, 'real', $real);


=head2 configure

This applies configuration to the current root filesystem. (i.e. it modifies whatever
VFS::FileSystem C<$VFS::root> currently points to)

If given an arrayref, it processes each element as another call to C<configure>.  If given a
plain scalar, it is assumed to be a file name.  Actual configuration directives come from a
hash:

B<< SECURITY NOTICE: This loads external modules in the VFS::FileSystem namespace, and can give
a perl script access to additional network resources. Do not allow configuration to be provided
from untrusted sources. >>

=over

=item C<< new => [ $class_suffix, @params ] >>

Call 'new' on class C<VFS::FileSystem::$class_suffix>.

=item C<< clone => [ $fs_name, @params ] >>

Instead of calling C<< $class->new(...) >>, call
C<< $filesystems{$fs_name}->clone(...) >>.

(it is an error to specify both 'new' and 'clone')

=item C<< name => $name >>

Assign or use a filesystem by symbolic name.  The symbolic name is separate from any name used
inside the filesystem, and useful for defining a filesystem first before mounting it at one or
more paths. If C<name> is already defined, you do not need to declare C<class>.  Think of it
like:

    defined $new || defined $clone
      ? ( $filesystems{$name}= $class->...(...) )
      : $filesystems{$name}

Initially, there are filesystems named 'root' and 'real'.

Assigning a new filesystem to 'root' immediately updates C<$VFS::root>, affecting all further
configuration.  C<'real'> may not be assigned, to preserve sanity.

=item C<< mount => $path >> or C<< mount => [$src, $dst] >>

Mount the resulting filesystem into the current C<$VFS::root> at C<$path>. You may specify a
C<< [$src,$dst] >> pair to mount a subset of the new filesystem.

=back

Examples:

  # mount --bind /foo /bar
  {
    name => 'root',
    mount => [ '/foo', '/bar' ]
  }
  
  # sshfs exmaple.com:/foo /bar
  {
    new => [ 'SFTP', host => 'example.com' ],
    mount => [ '/foo', '/bar' ]
  }
  
  # git
  {
    new => [ 'Git', git_dir => '~/example/.git' ],
    mount => [ 'master:/' => '/repo' ]
  }

=cut

sub configure :Export(-config) {
	# Handle the wide variety of ways arguments can be provided
	my $orig_err= $@;
	eval {
		my %conf;
		if (@_ > 1 && !ref $_[0] && !(@_ & 1)) {
			%conf= @_;
		} elsif (@_ != 1) {
			croak "Expected arrayref, hashref, filename, or even list of key/values";
		} elsif (!ref $_[0]) {
			# load a config file
			my $fname= $_[0];
			$fname =~ m{ ^ ( [.~] | [A-Za-z]: | ) ( [/\\] .* ) }x
				or croak "Expected absolute or relative file path: '$_[0]'";
			return configure(_load_config_file($_[0]));
		} elsif (ref $_[0] eq 'ARRAY') {
			return configure($_) for @{$_[0]};
		} elsif (ref $_[0] eq 'HASH') {
			%conf= %{$_[0]};
		}
		
		# Now we're down to one simple filesystem instruction
		_configure_filesystem(\%conf);
		1;
	}? ($@= $orig_err)
	: do {
		# Include helpful context info in error
		require JSON;
		my $context= JSON->new->encode(@_ > 1? \@_ : $_[0]);
		$@ =~ s/$/: $context/m;
		die $@;
	};
}
# {
#   name   => a global filesystem name to either use or create
#   new    => $CLASS or [ $CLASS => @args ]
#   clone  => $existing_fs_name or [ $existing_fs_name => @args ]
#   mount  => $dest_path or [ $src_path => $dest_path ]
# }
# Note: deletes keys from the argument.
sub _configure_filesystem {
	my ($conf)= @_;
	my ($name, $new, $clone, $mount)= delete @{$conf}{
	 qw( name   new   clone   mount )
	};
	carp "Unused configuration keys: ".join(', ', keys %$conf)
		if keys %$conf;
	croak "You may only specify one of 'new' or 'clone'"
		if $new && $clone;
	my $fs;
	if ($new) {
		my ($class, @args)= ref $new eq 'ARRAY'? @$new
			: !ref $new? ($new)
			: croak "Invalid specification for 'new'";
		defined $class && length $class
			or croak "Missing class in 'new' spec";
		require_module('VFS::FileSystem::'.$class);
		$fs= $class->new(@args);
	} elsif ($clone) {
		my ($from_name, @args)= ref $clone eq 'ARRAY'? @$clone
			: !ref $clone? ($clone)
			: croak "Invalid specification for 'clone'";
		defined $from_name && length $from_name
			or croak "Missing source name in 'clone' spec";
		$fs= $filesystem{$from_name}
			or croak "No filesystem named '$from_name', in clone spec";
		$fs= $fs->clone(@args);
	} elsif (defined $name) {
		$fs= $filesystem{$name}
			or croak "No filesystem named '$name'";
	} else {
		croak "No filesystem specified";
	}
	if (defined $name && $filesystem{$name} != $fs) {
		croak "Refusing to replace filesystem 'real'" if $name eq 'real';
		$filesystem{$name}= $fs;
	}
	
	if ($mount) {
		my ($srcpath, $dstpath)= ref $mount eq 'ARRAY'? @$mount
			: !ref $mount? ( '/', $mount )
			: croak "Invalid specification for 'mount'";
		$root->mount($fs, $srcpath, $dstpath);
	}
}

sub _load_config_file {
	my $path= shift;
	if ($path =~ m{^~/}) { # this is a unix-ism not handled by the filesystem modules
		defined $ENV{HOME} && length $ENV{HOME}
			or croak 'Environment $HOME is not set';
		# Join with path separator already present in $path or $home.
		substr($path, 0, ($ENV{HOME} =~ m{ [/\\]$ }x? 1 : 0), $ENV{HOME});
	}
	my $path_obj= $real->path($path);
	my $text= $path->slurp;
	# Is there a BOM? 
	if ($text =~ /^ \xEF \xBB \xBF /x) { utf8::decode($text); }
	elsif ($text =~ /^ \xFE \xFF /x) { require Encode; $text= Encode::decode('UTF-16BE', $text) }
	elsif ($text =~ /^ \xFF \xFE /x) { require Encode; $text= Encode::decode('UTF-16LE', $text) }
	# No BOM, but if there are high characters, see if maybe they decode with UTF-8 anyway.
	elsif ($text =~ /[^\0-\x7F]/) { utf8::decode($text); } 
	
	if ($path =~ /\.ya?ml$/) {
		require YAML;
		return YAML::Load($text);
	} else {
		require JSON;
		JSON->new->utf8->relaxed->decode($text);
	}
}

=head2 path

This function behaves like L<Path::Class/dir> or L<Path::Tiny/path>.
It returns Path objects from the current C<$VFS::root> filesystem.

=cut

sub path :Export { $root->path(@_); }

=head2 cur_vol

Returns the current volume of the root filesystem.  On Unix, this is always
the empty string C<''>.  On Win32 it will be a string like 'C' or 'D'.

=head2 cur_dir

Returns the current directory for the root filesystem, used when resolving
relative paths.

=cut

sub cur_vol :Export { $root->cur_vol(@_) }
sub cur_dir :Export { $root->cur_dir(@_) }

=head2 temp_dir

Returns a directory that should be used for creating temporary files.

=cut

sub temp_dir :Export { $root->temp_dir(@_) }

1;

__END__

=head1 SEE ALSO

=over

=item L<Filesys::POSIX>

This module implements a full POSIX virtual filesystem, though as the name implies, it does not
handle any Windows concepts like volumes or alternate path separators.  It makes the odd choice
to throw exceptions for failed operations, including 'stat' which many users would use to test
for existence of files.  Tests currently fail on BSD and Win32.  Aside from these problems, it
is a very complete implementation.

Oddly, there don't seem to be any CPAN plugins built on it.

=item L<Filesys::Virtual>

This module intends to be a VFS, but lacks any specification of how the API should behave, and
was last updated in 2009. It also lacks an API for file ownership (chmod etc).

CPAN has implementations for SSH, DAAP, and a FUSE adapter to use it as the back-end for a real
mounted filesystem.

=item L<VFSsimple>

Very sparse API (insufficient for most uses), and last updated 2007.

CPAN has implementations for ISO, FTP, HTTP, and "rsync" (which just shells out to rsync to
clone a remote file system locally)

=item L<File::Redirect>

Same idea of redirecting global PerlIO into a module, but the implementation is limited to
C<stat> / C<open> / C<close>, uses XS, doesn't work on perls newer than 5.20, and was last
updated in 2012.

It comes with support for mounting Zip files into the virtual filesystem.

=back
