package ModuleBuildBuilder;

use strict;
use Module::Build;
use vars qw(@ISA);
@ISA = qw(Module::Build);


sub ACTION_distdir {
  my $self = shift;
  $self->SUPER::ACTION_distdir(@_);

  my $build_pl = File::Spec->catfile($self->dist_dir, qw(Build.PL));
  my $build_pm = File::Spec->catfile($self->dist_dir, qw(lib Module Build.pm));
  my $base_pm  = File::Spec->catfile($self->dist_dir, qw(lib Module Build Base.pm));
  my $api_pod  = File::Spec->catfile($self->dist_dir, qw(lib Module Build API.pod));

  open my($fh), $base_pm or die "Couldn't read $base_pm: $!";
  my %subs = map {$_,1} map +(/^\s*sub (\w+)/)[0], <$fh>;

  # Replace "<autogenerated_accessors>" with some POD lists
  my @need_doc = sort grep !$subs{$_}, $self->valid_properties;
  $self->do_replace(qq[s{<autogenerated_accessors>}{ join "\\n\\n", map "=item \$_()", qw(@need_doc) }e],
		    $api_pod);

  # Replace "<action_list>" with a list of actions
  my $action_text = $self->_action_listing(scalar $self->known_actions);
  $self->do_replace(qq[s{<action_list>}{$action_text}], $build_pm);

  # Finally, sneakily rewrite the Build.PL to use a vanilla
  # Module::Build object instead of a ModuleBuildBuilder.
  $self->do_replace(qq[BEGIN{\$/=undef} s{<remove_me>.*</remove_me>}{}gs], $build_pl);
  $self->do_replace(qq[s{ModuleBuildBuilder}{Module::Build}gs], $build_pl);

  # XXX Band-aid the signing here again, since we modified some files.
  $self->depends_on('distsign') if($self->sign);
}

sub do_replace {
  my ($self, $code, $file) = @_;
  $self->run_perl_script('-e', ['-pi.bak'], [$code, $file]);
  1 while unlink "$file.bak";
}

sub ACTION_patch_blead {
  my $self = shift;
  my $git_dir = $ARGV[1];
  die "Usage: Build patch_blead <perl-git-directory>\n"
    unless $git_dir && -d "$git_dir/.git" && -f "$git_dir/perl.h";

  $self->depends_on('build');

  $self->log_info( "Updating $git_dir\n" );
  $self->{properties}{verbose} = 1;

  # create a branch
  my $cwd = $self->cwd;
  chdir $git_dir;
  $self->do_system("git checkout -b " . $self->dist_dir)
    or die "Couldn't create git branch" . $self->dist_dir . "\n";
  chdir $cwd;

  # copy files
  (my $git_mb_dir = $git_dir) =~ s{/?$}{/cpan/Module-Build};
  my $files;

  $files = $self->rscan_dir('blib/lib');
  for my $file (@$files) {
    next unless -f $file;
    next if $file =~ /\.svn/;
    (my $dest = $file) =~ s{^blib}{$git_mb_dir};
    $self->copy_if_modified(from => $file, to => $dest);
  }

  $files = $self->rscan_dir('blib/script');
  for my $file (@$files) {
    next unless -f $file;
    next if $file =~ /\.svn/;
    (my $dest = $file) =~ s{^blib/script}{$git_mb_dir/scripts};
    $self->copy_if_modified(from => $file, to => $dest);
  }

  my @skip = qw{ t/par.t t/signature.t };
  $files = $self->rscan_dir('t');
  for my $file (@$files) {
    next unless -f $file;
    next if $file =~ /\.svn/;
    next if grep { $file eq $_ } @skip;
    my $dest = "$git_mb_dir/$file";
    $self->copy_if_modified(from => $file, to => $dest);
  }

  $self->copy_if_modified(from => 'Changes', to => "$git_mb_dir/Changes");
  return 1;
}

sub ACTION_upload {
  my $self = shift;

  $self->depends_on('checkchanges');
  $self->depends_on('checkgit');

  eval { require CPAN::Uploader; 1 }
    or die "CPAN::Uploader must be installed for uploading to work.\n";
  
  $self->depends_on('build');
  $self->depends_on('distmeta');
  $self->depends_on('distcheck');
  $self->depends_on('disttest');
  $self->depends_on('dist');

  my $uploader = $self->find_command("cpan-upload");

  if ( $self->y_n("Upload to CPAN?", 'y') ) {
    $self->do_system($uploader, $self->dist_dir . ".tar.gz") 
      or die "Failed to upload.\n";
      $self->depends_on('tag_git');
  }

  return 1;
}

sub ACTION_checkgit {
  my $self = shift;

  unless ( -d '.git' ) {
    $self->log_warn("\n*** This does not seem to be a git repository. Checks disabled ***\n");
    return 1;
  }

  eval { require Git::Wrapper; 1 }
    or die "Git::Wrapper must be installed to check the distribution.\n";
  
  my $git = Git::Wrapper->new('.');
  my @repos = $git->remote;
  if ( ! grep { /\Aorigin\z/ } @repos ) {
    die "You have no 'origin' repository. Aborting!\n"
  }

# Are we on the master branch?
  $self->log_info("Checking current branch...\n");
  my @branches = $git->branch;
  my ($cur_branch) = grep { /\A\*\s*\w/ } @branches;
  die "Can't determine current branch\n" unless $cur_branch;
  $cur_branch =~ s{\A\*\s+}{};
  if ( $cur_branch ne 'master' ) {
    unless ( $self->y_n("Are you sure you want to tag the '$cur_branch' branch?", 'n') ) {
      die "Aborting!\n";
    }
  }

# files checked in
  $self->log_info("Checking for files that aren't checked in...\n");
  my @diff = $git->diff('HEAD');
  if ( @diff ) {
    $self->log_warn( "Some files not checked in.  Aborting!\n\n" );
    $self->log_warn( join( "\n", $git->diff('--stat') ) . "\n" );
    exit 1;
  }

# check that we're up to date
  $self->log_info("Checking for differences from origin...\n");
  my @refs = split q{ }, join( "\n", $git->show_ref('refs/heads/master', 'refs/remotes/origin/master'));
  if ( ! ($refs[0] eq $refs[2] )) {
    $self->log_warn( "Local repo not in sync with origin.  Aborting!\n");
    $self->log_warn( "\nMaster refs:\n" );
    $self->log_warn( "$_\n" ) for $git->show_ref('master');
    exit 1;
  }
  
}

sub ACTION_tag_git {
  my $self = shift;

  unless ( -d '.git' ) {
    $self->log_warn("\n*** This does not seem to be a git repository. Tagging disabled ***\n");
    return 1;
  }

  eval { require Git::Wrapper; 1 }
    or die "Git::Wrapper must be installed to check the distribution.\n";
  
  my $git = Git::Wrapper->new('.');
  my $tag = $self->dist_version;
  $self->log_info("Tagging HEAD as $tag");
  $git->tag('-m', "tagging $tag", $tag);
  $self->log_info("Pushing tags to origin");
  $git->push('--tags');
  return 1;
}

sub ACTION_checkchanges {
  my $self = shift;

  # Changes
  $self->log_info( "Here is the start of Changes:" );
  system("head -10 Changes");
  unless ( $self->y_n("Have you updated the Changes file with the tag and date?", 'n') ) {
    die "Aborting!\n";
  }

  return 1;
}




1;
