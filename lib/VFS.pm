package VFS;
use v5.18;
use Exporter::Extensible -exporter_setup => 1;
use Carp;
use VFS::FileSystem::PerlIO;

our $VERSION= 0; #VERSION
#ABSTRACT: Virtual Filesystem for Perl

=head1 DESCRIPTION

This package collection gives you the ability to show virtual file paths to
your program with arbitrary back-ends, such as Zip files, git object trees,
or SFTP.  In short, it lets you do the kinds of things a Linux FUSE module
would let you do but without root access, and is available cross-platform.

The L<VFS::FileSystem> object provides object-oriented access to filesystem
instances.  The global variable C<$VFS::root> provides a default filesystem
for function-ccess.  Bold users who like to live dangerously may also use
the "-override_core" option to intercept all of Perl's core filesystem
functions (but you must load VFS before all other modules for that to work)

The structure of the VFS can be loaded from a config file, but no config file
is loaded by default.  This can be specified on the commandline or PERL5OPT
environment variable.

  PERL5OPT=-MVFS=/path/to/config.json

You could also configure it programmatically in
C<< $Config{sitelib}/sitecustomize.pl >> if that is enabled for your installed
perl.  Note that mount points are loaded lazily, so if you configure a bunch
of SFTP sites it won't immediately try connecting to them at startup.

=head1 MEET THE OBJECTS

=over

=item L<VFS::FileSystem>

This represents a virtual filesystem, composed of named volumes at the root,
each with a file tree under it.  Filesystems may be mounted at any path
within another filesystem.

=item L<VFS::Path>

Filesystems return these objects to represent unopened files.  A filesystem
will always allow generic "component" paths (a list of directory names ending
with file name) but may also allow other types of path objects depending on
what is available from the back-end.  Paths hold a strong reference to the
originating filesystem.

=item L<VFS::File>

This represents an open file, and will be a blessed GLOB ref which also
descends from IO::File, for maximum compatibility.  Files hold a strong
reference to the originating filesystem.

=back

=head1 EXPORTS

All L</functions> may be exported.  The following additional items can be
requested form the C<use VFS ...> line:

=over

=item C<< -config => $filename_or_data >>

This is a shorthand to calling L</VFS::configure> at module-load time.

=item C<< /conf >>, C<< ./conf >>, C<< ~/conf >>, C<< C:\conf >>

Any option starting with C<<qr{ [^.~] / }x>> (or C<<qr{ (?: [A-Z] : )? \\ }x>>
on Win32) will automatically be treated as the filename for the C<-config>
option.

=item C<< -override_core >>

This requests VFS to intercept all CORE:: filesystem functions and make them
read and write through the configured virtual filesystem.  This is only
possible very early in startup before other modules have been loaded.

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

This returns the root VFS::FileSystem object.  It is nothing more than a
read-accesor for C<$VFS::filesystem{root}>.  You may change the root by setting
or localizing that variable.

The initial value for C<root> is a clone of L</real>.

=head2 real

This returns a VFS::FileSystem that reads the real filesystem perl is running
in.  It is a read-accessor for C<$VFS::filesystem{real}>. You should probably
not change that variable.

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

This applies configuration to the current root filesystem. (i.e. it modifies
whatever VFS::FileSystem C<$VFS::root> currently points to)

If given an arrayref, it processes each element as another call to C<configure>.
If given a plain scalar, it is assumed to be a file name.  Actual configuration
directives come from a hash:

B<< SECURITY NOTICE: This loads external modules in the VFS::FileSystem
namespace, and can give a perl script access to additional network resources.
Do not allow configuration to be provided from untrusted sources. >>

=over

=item C<< new => [ $class_suffix, @params ] >>

Call 'new' on class C<VFS::FileSystem::$class_suffix>.

=item C<< clone => [ $fs_name, @params ] >>

Instead of calling C<< $class->new(...) >>, call
C<< $filesystems{$fs_name}->clone(...) >>.

(it is an error to specify both 'new' and 'clone')

=item C<< name => $name >>

Assign or use a filesystem by symbolic name.  The symbolic name is separate
from any name used inside the filesystem, and useful for defining a filesystem
first before mounting it at one or more paths. If C<name> is already defined,
you do not need to declare C<class>.  Think of it like:

    defined $new || defined $clone
      ? ( $filesystems{$name}= $class->...(...) )
      : $filesystems{$name}

Initially, there are filesystems named 'root' and 'real'.

Assigning a new filesystem to 'root' immediately updates C<$VFS::root>,
affecting all further configuration.  C<'real'> may not be assigned,
to preserve sanity.

=item C<< mount => $path >> or C<< mount => [$src, $dst] >>

Mount the resulting filesystem into the current C<$VFS::root> at C<$path>.
You may specify a C<< [$src,$dst] >> pair to mount a subset of the new
filesystem.

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
		my ($name, $new, $clone, $mount)= delete @conf{
		 qw( name   new   clone   mount )
		};
		carp "Unused configuration keys: ".join(', ', keys %conf)
			if keys %conf;
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
		JSON->new->decode($text);
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
