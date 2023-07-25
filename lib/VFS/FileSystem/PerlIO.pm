package VFS::FileSystem::PerlIO;
use strict;
use warnings;
use parent 'VFS::FileSystem';
use Cwd ();
our $core_getcwd= \&Cwd::getcwd;

sub getcwd {
	$core_getcwd->(@_);
}

sub chdir {
	@_? CORE::chdir(@_) : CORE::chdir;
}

sub opendir {
	CORE::opendir($_[0], $_[1]);
}

sub readdir {
	my ($self, $dir_fh)= @_;
	CORE::readdir($dir_fh);
}

sub closedir {
	CORE::closedir(@_);
}

sub open {
	CORE::open(@_);
}

1;
