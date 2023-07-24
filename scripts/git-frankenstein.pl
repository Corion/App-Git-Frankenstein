#!perl
use 5.020;
use feature 'signatures';
no warnings 'experimental::signatures';

use IPC::Run3;
use Text::Table;
use List::Util 'max';

use Getopt::Long;

GetOptions(
    's|source-repository=s' => \my $source_repository,
    's|source-directory=s' => \my $source_directory,
    't|target-repository=s' => \my $target_repository,
    'v|verbose'             => \my $verbose,
    'p=i'                   => \my $path_segments,
);

# This is very local to my setup
$source_directory //= 'template';
$path_segments    //= 2;
$source_repository //= '/home/corion/Projekte/Dist-Template/';

$target_repository //= '.';

die "'$target_repository': Not a git repository"
    unless -d "$target_repository/.git";

my ($action, @refspec) = @ARGV;

if( $action eq 'list' ) {
    # ... nothing to do here
    die "Can't list _and_ apply patches"
        if @refspec;

} elsif( $action eq 'auto' ) {
    # ... nothing to do here
    die "Can't combine 'auto' with patches"
        if @refspec;

} elsif( $action ne 'apply' ) {
    $action = 'apply';
    unshift @refspec, $action;
}

sub trimmed(@lines) {
    s!\s+$!! for @lines;
    return @lines;
}

sub run(@command) {
    if( $verbose ) {
        say "@command";
    }
    run3(\@command, \undef, \my @stdout, \my @stderr, {
        return_if_system_error => 1,
        binmode_stdout => ':utf8',
    }) == -1 and warn "Command [@command] failed: $! / $?";
    return trimmed(@stdout);
}

sub run_pipe($options, @command) {
    my $stdin = delete $options->{ stdin };
    my $silent = delete $options->{ silent };
    if( $verbose ) {
        say "| @command";
    }
    run3(\@command, \$stdin, \my @stdout, \my @stderr, {
        return_if_system_error => 1,
        binmode_stdout => ':utf8',
    }) == -1 and warn "Command [@command] failed: $! / $?";
    if( !$silent and @stderr ) {
        warn "$_" for @stderr;
    }
    return trimmed(@stdout);
}

sub git(@command) {
    return run(git => @command)
}

sub git_pipe($options, @command) {
    return run_pipe($options, git => @command)
}

sub changed_files_by_commit( $this_commit ) {
    return git("diff-tree" => '--name-only', '--no-commit-id', '-r', $this_commit)
}

sub commit_file_diff_vis( $title1, $title2, $diff ) {
    my $table = Text::Table->new($title1,$title2);
    $diff->{left} //= [];
    $diff->{right} //= [];
    my $rowcount = max scalar $diff->{left}->@*, scalar $diff->{right}->@*;
    my @rows = map {
        [$diff->{left}->[$_] // '',$diff->{right}->[$_]//'']
    } 0..$rowcount -1;
    $table->load(@rows);
    return "$table";
}

sub raw_commit( $commit ) {
    my @commit = git('--no-pager', log => '-U0', '--patch', '-n', 1, '--no-decorate', $commit);
    # Strip off the commit message since I don't know how to make `git log` do it
    while( $commit[0] !~ /^index/ ) {
        shift @commit;
    }
    return @commit
}

sub commit_message( $repo, $commit ) {
    my @msg = git( '-C', $repo, 'log' => '--format=%B', '-n', 1, $commit );
    pop @msg while (@msg and $msg[-1] eq '');
    return @msg
}

sub patch_applies( $repo, $diff ) {
    my @msg = git_pipe( { stdin => $diff, silent => 1 } => '-C', $repo, 'apply' => '--check', '-p', $path_segments, '-' );

    #if( $? ) {
    #    say $_ for @msg
    #}

    pop @msg while (@msg and $msg[-1] eq '');
    return @msg
}

# patch_applied = apply_patch --reverse

sub apply_patch( $repo, $diff ) {
    my @msg = git_pipe( { stdin => $diff } => '-C', $repo, 'am' => '-p', $path_segments, '-' );

    if( $? ) {
        say $_ for @msg
    }

    pop @msg while (@msg and $msg[-1] eq '');
    return @msg
}

# --relative?!
sub get_patch( $repo, $commit ) {
    my @msg = git( '-C', $repo, 'format-patch', '-1', '--stdout', "$commit~1..$commit" );
    pop @msg while (@msg and $msg[-1] eq '');
    return @msg
}

sub list_patches( $repo ) {
    my @msg = git( '-C', $repo, 'log', '--pretty=%H', $source_directory );
    pop @msg while (@msg and $msg[-1] eq '');
    return reverse @msg
}

sub process_ref( $ref, %options ) {
    my $p   = join "\n", get_patch($source_repository, $ref);
    my ($headline, @msg) = commit_message( $source_repository, $ref );
    if( patch_applies( $target_repository, $p ) == 0 and ! $?) {
        say "$ref $headline";
        if( $options{ apply }) {
            apply_patch( $target_repository, $p );
        }
    } else {
        if( $options{ apply } and not $options{ silent_fail }) {
            say "SKIP: $ref $headline";
        }
    }
}

sub cmd_apply(@refspec) {
    for my $ref (@refspec) {
        process_ref( $ref, apply => 1 );
    }
}

sub cmd_list() {
    my @patches = list_patches($source_repository);
    for my $ref (@patches) {
        process_ref( $ref, apply => 0 );
    }
}

sub cmd_apply_auto() {
    my @patches = list_patches($source_repository);
    for my $ref (@patches) {
        process_ref( $ref, apply => 1, silent_fail => 1 );
    }
}

if( $action eq 'apply' ) {
    cmd_apply( @refspec );
} elsif( $action eq 'list' ) {
    cmd_list();
} elsif( $action eq 'auto' ) {
    cmd_apply_auto();
}

__DATA__

[ ] Take latest (?) patch from Git in Dist-Template
[ ] Scan repos for affected file (later)
[ ] Take this repo (or from @ARGV)
[ ] Check if there are changes staged, if so, skip
[x] Check if patch would apply clean
[x] If it applies clean, apply and commit it
[ ] Show a list of commits that would apply cleanly
[ ] show a list of files that can be updated
