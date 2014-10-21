use Mojo::Base -strict;

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test'
  unless $ENV{TEST_ONLINE};

use Minion;

# Clean up before start
my $minion = Minion->new($ENV{TEST_ONLINE});
is $minion->prefix, 'minion', 'right prefix';
my $workers = $minion->workers;
my $jobs    = $minion->prefix('jobs_test')->jobs;
is $jobs->name, 'jobs_test.jobs', 'right name';
$_->options && $_->drop for $workers, $jobs;

# Tasks
my $add = $jobs->insert({results => []});
$minion->add_task(
  add => sub {
    my ($job, $first, $second) = @_;
    my $doc = $job->worker->minion->jobs->find_one($add);
    push @{$doc->{results}}, $first + $second;
    $job->worker->minion->jobs->save($doc);
  }
);
$minion->add_task(exit => sub { exit 1 });
$minion->add_task(fail => sub { die "Intentional failure!\n" });

# Enqueue, dequeue and perform
my $oid = $minion->enqueue(add => [2, 2]);
my $doc = $jobs->find_one({task => 'add'});
is $doc->{_id}, $oid, 'right object id';
is_deeply $doc->{args}, [2, 2], 'right arguments';
ok $doc->{created}->to_epoch, 'has timestamp';
is $doc->{priority}, 0,          'right priority';
is $doc->{state},    'inactive', 'right state';
my $worker = $minion->worker;
is $worker->dequeue, undef, 'not registered';
my $job = $worker->register->dequeue;
is_deeply $job->doc->{args}, [2, 2], 'right arguments';
is $job->doc->{state}, 'active', 'right state';
is $job->doc->{task},  'add',    'right task';
is $workers->find_one($job->doc->{worker})->{pid}, $$, 'right worker';
$job->perform;
is_deeply $jobs->find_one($add)->{results}, [4], 'right result';
is $jobs->find_one($oid)->{state}, 'finished', 'right state';
$worker->unregister;

# Jobs with priority
$minion->enqueue(add => [1, 2]);
$oid = $minion->enqueue(add => [2, 4], {priority => 1});
$job = $worker->register->dequeue;
is $job->doc->{_id}, $oid, 'right object id';
$job->finish;
isnt $worker->dequeue->{_id}, $oid, 'different object id';
$job->finish;
$worker->unregister;

# Failed jobs
$oid = $minion->enqueue(add => [5, 6]);
$job = $worker->register->dequeue;
is $job->doc->{_id}, $oid, 'right object id';
$job->fail;
$doc = $jobs->find_one($oid);
is $doc->{state}, 'failed',         'right state';
is $doc->{error}, 'Unknown error.', 'right error';
$oid = $minion->enqueue(add => [6, 7]);
$job = $worker->dequeue;
is $job->doc->{_id}, $oid, 'right object id';
$job->fail('Something bad happened!');
$doc = $jobs->find_one($oid);
is $doc->{state}, 'failed', 'right state';
is $doc->{error}, 'Something bad happened!', 'right error';
$oid = $minion->enqueue('fail');
$job = $worker->dequeue;
is $job->doc->{_id}, $oid, 'right object id';
$job->perform;
$doc = $jobs->find_one($oid);
is $doc->{state}, 'failed', 'right state';
is $doc->{error}, "Intentional failure!\n", 'right error';
$worker->unregister;

# Exit
$oid = $minion->enqueue('exit');
$job = $worker->register->dequeue;
is $job->doc->{_id}, $oid, 'right object id';
$job->perform;
$doc = $jobs->find_one($oid);
is $doc->{state}, 'failed', 'right state';
is $doc->{error}, 'Non-zero exit status.', 'right error';
$worker->unregister;
$_->drop for $workers, $jobs;

done_testing();
