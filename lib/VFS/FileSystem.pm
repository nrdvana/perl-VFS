package VFS::FileSystem;
use strict;
use warnings;
use Carp;

sub new {
	my $class= shift;
	my %attrs= @_ == 1 && ref $_[0] eq 'HASH'? %{$_[0]}
		: !(@_ & 1)? @_
		: croak "Expected even-length key/value pairs, or hashref";
	$attrs{cur_dir} //= { '' => '/' };
	$attrs{cur_vol} //= '';
	$attrs{mount}  //= {};
	bless \%attrs, $class;
}

sub clone {
	my $self= shift;
	my %attrs= %$self;
	$self= bless \%attrs, ref $self;
	$attrs{cur_dir}= { $attrs{cur_dir}->%* };
	$_= $self->path($_) for values $attrs{cur_dir}->%*;
	$attrs{mount}= { $attrs{mount}->%* };
	return $self;
}

sub cur_vol { '' }

sub cur_dir {
	my ($self, $volume)= @_;
	$volume //= $self->cur_vol;
	exists $self->{cur_dir}{$volume} or croak "No such volume '$volume'";
	return $self->{cur_dir}{$volume};
}

sub cwd { shift->cur_dir(@_) }

sub chdir {
	my $self= shift;
	my $path= $self->abs_path(@_);
	$self->{cur_dir}{$self->{cur_vol}}= $path;
}

sub volume {
	my ($self, $name)= @_;
	...
}

sub path {
	my ($self, @spec)= @_;
	...
}

sub abs_path {
	my ($self, @spec)= @_;
	...
}

sub temp_dir {
	...
}

1;
