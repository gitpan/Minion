use Mojo::Base -strict;

use Test::More;

plan skip_all => 'set TEST_ONLINE to enable this test'
  unless $ENV{TEST_ONLINE};

use Mango::BSON qw(bson_oid bson_time);
use Minion;
use Mojo::IOLoop;

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
    my $doc = $job->minion->jobs->find_one($add);
    push @{$doc->{results}}, $first + $second;
    $job->minion->jobs->save($doc);
  }
);
$minion->add_task(exit => sub { exit 1 });
$minion->add_task(fail => sub { die "Intentional failure!\n" });

# Stats
my $stats = $minion->stats;
is $stats->{active_workers},   0, 'no active workers';
is $stats->{inactive_workers}, 0, 'no inactive workers';
is $stats->{active_jobs},      0, 'no active jobs';
is $stats->{failed_jobs},      0, 'no failed jobs';
is $stats->{finished_jobs},    0, 'no finished jobs';
is $stats->{inactive_jobs},    0, 'no inactive jobs';
my $worker = $minion->worker->register;
is $minion->stats->{inactive_workers}, 1, 'one inactive worker';
$minion->enqueue('fail');
$minion->enqueue('fail');
is $minion->stats->{inactive_jobs}, 2, 'two inactive jobs';
my $job = $worker->dequeue;
$stats = $minion->stats;
is $stats->{active_workers}, 1, 'one active worker';
is $stats->{active_jobs},    1, 'one active job';
is $stats->{inactive_jobs},  1, 'one inactive job';
ok $job->finish, 'job finished';
is $minion->stats->{finished_jobs}, 1, 'one finished job';
$job = $worker->dequeue;
ok $job->fail, 'job failed';
is $minion->stats->{failed_jobs}, 1, 'one failed job';
ok $job->restart, 'job restarted';
is $minion->stats->{failed_jobs}, 0, 'no failed jobs';
ok $worker->dequeue->finish, 'job finished';
$worker->unregister;
$stats = $minion->stats;
is $stats->{active_workers},   0, 'no active workers';
is $stats->{inactive_workers}, 0, 'no inactive workers';
is $stats->{active_jobs},      0, 'no active jobs';
is $stats->{failed_jobs},      0, 'one failed job';
is $stats->{finished_jobs},    2, 'one finished job';
is $stats->{inactive_jobs},    0, 'no inactive jobs';

# Enqueue, dequeue and perform
is $minion->job(bson_oid), undef, 'job does not exist';
my $oid = $minion->enqueue(add => [2, 2]);
my $doc = $jobs->find_one({task => 'add'});
is $doc->{_id}, $oid, 'right object id';
is_deeply $doc->{args}, [2, 2], 'right arguments';
is $doc->{priority}, 0,          'right priority';
is $doc->{state},    'inactive', 'right state';
$worker = $minion->worker;
is $worker->dequeue, undef, 'not registered';
ok !$minion->job($oid)->started, 'no started timestamp';
$job = $worker->register->dequeue;
like $job->created, qr/^[\d.]+$/, 'has created timestamp';
like $job->started, qr/^[\d.]+$/, 'has started timestamp';
is_deeply $job->args, [2, 2], 'right arguments';
is $job->state, 'active', 'right state';
is $job->task,  'add',    'right task';
is $workers->find_one($jobs->find_one($job->id)->{worker})->{pid}, $$,
  'right worker';
ok !$job->finished, 'no finished timestamp';
$job->perform;
like $job->finished, qr/^[\d.]+$/, 'has finished timestamp';
is_deeply $jobs->find_one($add)->{results}, [4], 'right result';
$doc = $jobs->find_one($job->id);
is $doc->{state}, 'finished', 'right state';
$worker->unregister;
$job = $minion->job($job->id);
is_deeply $job->args, [2, 2], 'right arguments';
is $job->state, 'finished', 'right state';
is $job->task,  'add',      'right task';

# Restart and remove
$oid = $minion->enqueue(add => [5, 6]);
$job = $worker->register->dequeue;
is $job->restarts, 0, 'job has not been restarted';
is $job->id, $oid, 'right object id';
ok $job->finish, 'job finished';
ok !$worker->dequeue, 'no more jobs';
$job = $minion->job($oid);
ok !$job->restarted, 'no restarted timestamp';
ok $job->restart,     'job restarted';
like $job->restarted, qr/^[\d.]+$/, 'has restarted timestamp';
is $job->state,       'inactive', 'right state';
is $job->restarts,    1, 'job has been restarted once';
$job = $worker->dequeue;
ok !$job->restart, 'job not restarted';
is $job->id, $oid, 'right object id';
ok !$job->remove, 'job has not been removed';
ok $job->fail,     'job failed';
ok $job->restart,  'job restarted';
is $job->restarts, 2, 'job has been restarted twice';
ok !$job->finished, 'no finished timestamp';
ok !$job->started,  'no started timestamp';
$doc = $jobs->find_one($oid);
ok !$doc->{error},  'no error';
ok !$doc->{worker}, 'no worker';
$job = $worker->dequeue;
is $job->state, 'active', 'right state';
ok $job->finish, 'job finished';
ok $job->remove, 'job has been removed';
is $job->state,  undef, 'no state';
$oid = $minion->enqueue(add => [6, 5]);
$job = $worker->dequeue;
is $job->id, $oid, 'right object id';
ok $job->fail,   'job failed';
ok $job->remove, 'job has been removed';
is $job->state,  undef, 'no state';
$oid = $minion->enqueue(add => [5, 5]);
$job = $minion->job($oid);
ok $job->remove, 'job has been removed';
$worker->unregister;

# Jobs with priority
$minion->enqueue(add => [1, 2]);
$oid = $minion->enqueue(add => [2, 4], {priority => 1});
$job = $worker->register->dequeue;
is $job->id, $oid, 'right object id';
is $job->priority, 1, 'right priority';
ok $job->finish, 'job finished';
isnt $worker->dequeue->id, $oid, 'different object id';
$worker->unregister;

# Delayed jobs
$oid = $minion->enqueue(
  add => [2, 1] => {delayed => bson_time((time + 100) * 1000)});
is $worker->register->dequeue, undef, 'too early for job';
$doc = $jobs->find_one($oid);
$doc->{delayed} = bson_time((time - 100) * 1000);
$jobs->save($doc);
$job = $worker->dequeue;
is $job->id, $oid, 'right object id';
like $job->delayed, qr/^[\d.]+$/, 'has delayed timestamp';
ok $job->finish, 'job finished';
$worker->unregister;

# Enqueue non-blocking
my ($fail, $result) = @_;
$minion->enqueue(
  add => [23] => {priority => 1} => sub {
    my ($minion, $err, $oid) = @_;
    $fail   = $err;
    $result = $oid;
    Mojo::IOLoop->stop;
  }
);
Mojo::IOLoop->start;
ok !$fail, 'no error';
$worker = $minion->worker->register;
$job    = $worker->dequeue;
is $job->id, $result, 'right object id';
is_deeply $job->args, [23], 'right arguments';
is $job->priority, 1, 'right priority';
ok $job->finish, 'job finished';
$worker->unregister;

# Events
my ($failed, $finished) = (0, 0);
$minion->on(
  worker => sub {
    my ($minion, $worker) = @_;
    $worker->on(
      dequeue => sub {
        my ($worker, $job) = @_;
        $job->on(failed   => sub { $failed++ });
        $job->on(finished => sub { $finished++ });
      }
    );
  }
);
$worker = $minion->worker->register;
$minion->enqueue(add => [3, 3]);
$minion->enqueue(add => [4, 3]);
$job = $worker->dequeue;
is $failed,   0, 'failed event has not been emitted';
is $finished, 0, 'finished event has not been emitted';
$job->finish;
$job->finish;
is $failed,   0, 'failed event has not been emitted';
is $finished, 1, 'finished event has been emitted once';
$job = $worker->dequeue;
my $err;
$job->on(failed => sub { $err = pop });
$job->fail("test\n");
$job->fail;
is $err,      "test\n", 'right error';
is $failed,   1,        'failed event has been emitted once';
is $finished, 1,        'finished event has been emitted once';
$worker->unregister;

# Failed jobs
$oid = $minion->enqueue(add => [5, 6]);
$job = $worker->register->dequeue;
is $job->id, $oid, 'right object id';
is $job->error, undef, 'no error';
ok $job->fail, 'job failed';
ok !$job->finish, 'job not finished';
is $job->state, 'failed',         'right state';
is $job->error, 'Unknown error.', 'right error';
$oid = $minion->enqueue(add => [6, 7]);
$job = $worker->dequeue;
is $job->id, $oid, 'right object id';
ok $job->fail('Something bad happened!'), 'job failed';
is $job->state, 'failed', 'right state';
is $job->error, 'Something bad happened!', 'right error';
$oid = $minion->enqueue('fail');
$job = $worker->dequeue;
is $job->id, $oid, 'right object id';
$job->perform;
is $job->state, 'failed', 'right state';
is $job->error, "Intentional failure!\n", 'right error';
$worker->unregister;

# Exit
$oid = $minion->enqueue('exit');
$job = $worker->register->dequeue;
is $job->id, $oid, 'right object id';
$job->perform;
is $job->state, 'failed', 'right state';
is $job->error, 'Non-zero exit status.', 'right error';
$worker->unregister;
$_->drop for $workers, $jobs;

done_testing();