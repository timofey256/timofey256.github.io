---
layout: distill
title: an overview of C# multithreading
date: 2025-07-15
description: notes i've taken while refreshing my knowledge
tags: csharp
categories: programming

toc:
  - name: Threads
  - name: Tasks, Await, and Concurrency
  - name: Data Parallelism
  - name: Atomicity, Visibility, and Locks
  - name: Basic Synchronization Primitives
  - name: Producer-Consumer Pattern
  - name: Streaming Data using IAsyncEnumerable
  - name: Async-Compatible Initialization

_styles: >
  h2 {
    margin-top: 1em;
    margin-bottom: 1em;
  }

  h4 {
    margin-top: 1em;
  }
---

I've recently taken some time to refresh my understanding of multithreading in C#. This post is a collection of notes I wrote down along the way. It’s not a tutorial - more of a compact reference I (and you) can return to when there's a need to recall how things work.

It covers core concepts like threads, tasks, synchronization primitives, data parallelism, async streams, and more. I’ve included practical examples and benchmarks where they make sense, but the goal isn't to teach everything from scratch—just to gather the important patterns, behaviors, and gotchas in one place.

---

## Threads

```csharp
void MethodName() { /* do smth */ }

Thread t1 = new Thread(MethodName);
t1.Start();
t1.Join();
t1.Interrupt();                 // abort if blocked
t1.IsBackground = true;
t1.Priority = ThreadPriority.Highest;

int id = Thread.CurrentThread.ManagedThreadId;
```

_Default stack size of a .NET thread is 1 MiB_. You can change it by passing `stackSize` in the ctor:

```csharp
var t = new Thread(SomeMethod, stackSize: 512 * 1024);
```

---

## Tasks, Await, and Concurrency

Tasks represent units of work, while Threads are C# abstractions over OS Threads.

#### Threads vs Tasks

|             | `Thread`                      | `Task`                  |
| ----------- | ----------------------------- | ----------------------- |
| Represents  | running OS thread             | unit of work            |
| Create with | `new Thread`                  | `Task.Run` (ThreadPool) |
| Use for     | long‑lived, STA, custom stack | bursty CPU or async I/O |

#### ConfigureAwait

How await works by default

- The compiler inserts an awaiter for every await task;.
- Just before suspension it captures the current
  - SynchronizationContext (if one exists, e.g., WinForms/WPF UI thread, classic ASP.NET request thread) or
  - the current TaskScheduler (usually the ThreadPool).
- When task completes, the continuation is posted back to that captured context so your method keeps executing on the original thread.

`ConfigureAwait(bool)` lets you to set if you want this capture to happen or not. So we can roughly make the following distinction:

```text
UI apps (WinForms/WPF)    : ConfigureAwait(true)
Libraries / ASP.NET Core  : ConfigureAwait(false)
```

#### Task continuations

A continuation is code that runs after a `Task` completes, without blocking the current thread. You define it using the `ContinueWith` method:

```csharp
Task first = SomeTask();
first.ContinueWith(t => Console.WriteLine("This runs after SomeTask completes."));
```

This creates a dependency chain between tasks.

#### Be careful with chained task continuations

Can you spot a problem here? What the below code will print? Is it expected?

```csharp
static Task DoFirstThing()
{
    return Task.Run(() => Console.WriteLine("First thing done"));
}

static Task DoSecondThing()
{
    return Task.Delay(1000).ContinueWith(_ => Console.WriteLine("Second thing done"));
}

static Task DoThirdThing()
{
    return Task.Run(() => Console.WriteLine("Third thing done"));
}

static void Main(string[] args)
{
    DoFirstThing().ContinueWith(_ => DoSecondThing()).ContinueWith(_ => DoThirdThing());

    Console.ReadLine();
}
```

{% details Open see the answer %}
Program output:

```text
First thing done.
Third thing done.
Second thing done.
```

Order is wrong because of the incorrect usage of continuations. In `DoSecondThing()` we return a `Task<Task>`, because `ContinueWith` always returns `Task<T>` where `T` is the return type of the delegate which is Task in this case. The next `ContinueWith` will just unwrap the first `Task`, getting `Task`, so will not await anything.

The correct usage would be:

```csharp
DoFirstThing().ContinueWith(_ => DoSecondThing()).Unwrap().ContinueWith(_ => DoThirdThing());
```

Alternatively, you could use 3 `await` lines, or nested continuations.

{% enddetails %}

#### Timeout / cancellation

You can add timeouts to awaits:

```csharp
await DoWorkAsync().WaitAsync(TimeSpan.FromSeconds(2));
```

#### `Task.Run` vs `Task.Factory.StartNew`

`Task.Run(f)` ≈ `Task.Factory.StartNew(f, TaskCreationOptions.DenyChildAttach).Unwrap()`.

---

## Data Parallelism

Data parallelism refers to scenarios in which the same operation is performed concurrently (that is, in parallel) on elements in a source collection or array. In data parallel operations, the source collection is partitioned so that multiple threads can operate on different segments concurrently.

Let's try to implement some data parallelism using raw tasks - we will have an array `bitmaps` and we want to apply `ApplyFilter` on each of its elements.

```csharp
int degree = Environment.ProcessorCount;
int chunk  = (int)Math.Ceiling(bitmaps.Length / (double)degree);

var tasks = Enumerable.Range(0, degree).Select(core => Task.Run(() =>
{
    int start = core * chunk;
    int end   = Math.Min(start + chunk, bitmaps.Length);

    for (int i = start; i < end; i++)
        bitmaps[i] = ApplyFilter(bitmaps[i]);
})).ToArray();

await Task.WhenAll(tasks);
```

As you see, we had to deal with a lot of low-level things - specifying chunk sizes, manually calculating indices, etc. It's easy to make bugs when writing code like this.

Fortunately, .NET Task Parallel Library (TPL) has `System.Threading.Tasks.Parallel` class. Using it we can rewrite the above code piece much more concisely:

```csharp
Parallel.For(0, bitmaps.Length, i =>
{
    bitmaps[i] = ApplyFilter(bitmaps[i]);
});
```

#### `Parallel` also supports Async

Fetching a resource w/o `Parallel`:

```csharp
using var sem = new SemaphoreSlim(2);
var tasks = urls.Select(async url =>
{
    await sem.WaitAsync();
    try   { await FetchAsync(url, CancellationToken.None); }
    finally { sem.Release(); }
});
await Task.WhenAll(tasks);
```

With `Parallel`:

```csharp
await Parallel.ForEachAsync(urls,
    new ParallelOptions { MaxDegreeOfParallelism = 2 },
    async (url, ct) => await FetchAsync(url, ct));
```

#### `Parallel.ForEachAsync` vs `Task.WhenAll`

You can see above a useful feature of `Parallel.ForEachAsync`: it let's you specify degree of your parallelism.

---

## Atomicity, Visibility, and Locks

#### volatile

Guarantees reads/writes hit main memory and adds fences that stop CPU/compiler re‑ordering.

#### `System.Threading.Interlocked`

```csharp
int counter = 0;
Interlocked.Increment  (ref counter);
Interlocked.Decrement  (ref counter);
Interlocked.Add        (ref counter, 5);
int old = Interlocked.Exchange(ref counter, 100);
Interlocked.CompareExchange(ref counter, 10, 5); // set to 10 only when counter == 5
```

#### Interlocked vs lock (benchmark)

Why should you use `Interlocked` instead of `lock` whenever you can? Let's compare their performance.

{% details Open to see the benchmark code %}

```csharp
class CompareInterlockedAndLockProgram
{
    static int N = 1_000_000; // Increments per thread
    static int T = 4;         // Number of threads

    static void RunWithInterlocked()
    {
        int counter = 0;

        void Work()
        {
            for (int i = 0; i < N; i++)
                Interlocked.Increment(ref counter);
        }

        Thread[] threads = new Thread[T];
        Stopwatch sw = Stopwatch.StartNew();

        for (int i = 0; i < T; i++) threads[i] = new Thread(Work);
        foreach (var t in threads) t.Start();
        foreach (var t in threads) t.Join();

        sw.Stop();
        Console.WriteLine($"Interlocked: {sw.ElapsedMilliseconds} ms | Final = {counter}");
    }

    static void RunWithLock()
    {
        int counter = 0;
        object lockObj = new object();

        void Work()
        {
            for (int i = 0; i < N; i++)
            {
                lock (lockObj)
                {
                    counter++;
                }
            }
        }

        Thread[] threads = new Thread[T];
        Stopwatch sw = Stopwatch.StartNew();

        for (int i = 0; i < T; i++) threads[i] = new Thread(Work);
        foreach (var t in threads) t.Start();
        foreach (var t in threads) t.Join();

        sw.Stop();
        Console.WriteLine($"Lock:       {sw.ElapsedMilliseconds} ms | Final = {counter}");
    }

    public static void Start()
    {
        RunWithInterlocked();
        RunWithLock();
    }
}

class Program {
    public static void Main(string[] args) {
       CompareInterlockedAndLockProgram.Start();
    }
}
```

{% enddetails %}

Typical run on 4 threads × 1 M increments each:

```
Interlocked: 42 ms | Final = 4000000
Lock:       101 ms | Final = 4000000
```

---

## Basic Synchronization Primitives

### SemaphoreSlim

Control how many concurrent callers enter a critical section. `SemaphoreSlim` is also async‑friendly.
Limit a CPU‑bound method to 2 parallel executions.

```csharp
SemaphoreSlim sem = new(2, 2);

async Task WorkAsync()
{
    await sem.WaitAsync();           // ↓ counter or wait
    try   { await DoHeavyStuff(); }
    finally { sem.Release(); }       // ↑ counter
}
```

---

#### ManualResetEventSlim

One thread signals many waiters; stays signalled until reset.
Let all tasks start only after a warm‑up step.

```csharp
var go = new ManualResetEventSlim(false);

Task.Run(() => { WarmUp(); go.Set(); });        // signal ON

Parallel.For(0, 8, i =>
{
    go.Wait();                                  // all block here
    Process(i);
});
```

---

#### AutoResetEventSlim

Signal wakes **one** waiter, then auto‑resets.
Classic producer–consumer hand‑shake.

```csharp
var evt = new AutoResetEventSlim(false);

Task.Run(() =>                        // producer
{
    while (Produce(out var item))
    {
        queue.Enqueue(item);
        evt.Set();                    // wake one consumer
    }
});

Task.Run(() =>                        // consumer
{
    while (true)
    {
        evt.Wait();                   // waits again after each Set()
        if (queue.TryDequeue(out var x)) Use(x);
    }
});
```

---

#### CountdownEvent

**Fork / join**: continue when _n_ signals have arrived.
Fire off N raw threads, wait for all to finish.

```csharp
int N = 3;
var cd = new CountdownEvent(N);

for (int i = 0; i < N; i++)
    new Thread(() => { Work(); cd.Signal(); }).Start();

cd.Wait();                            // resumes when Signal() called N times
```

---

#### Barrier

Multi‑phase workflow: every participant must reach the barrier before any enters the next phase.
4 workers perform Stage 1 → Stage 2 → Stage 3 in lock‑step.

```csharp
var barrier = new Barrier(4, _ => Console.WriteLine("Phase done"));

for (int i = 0; i < 4; i++)
    Task.Run(() =>
    {
        Stage1(); barrier.SignalAndWait();
        Stage2(); barrier.SignalAndWait();
        Stage3(); barrier.SignalAndWait();
    });
```

---

## Producer-Consumer Pattern

Producer-Consumer decouples data creation from data processing: producers push items into a shared buffer while consumers pull them out. In .NET you can choose a blocking queue (`BlockingCollection<T>`) or the modern async‑friendly `Channel<T>` (you should use the latter most of the time).

#### Blocking Collection (thread‑blocking)

<aside><p> We use <code>Thread.Sleep</code> here for demonstration. In real code, consider using <code>await Task.Delay</code> for non-blocking waiting. </p></aside>
```csharp
var queue = new BlockingCollection<int>(boundedCapacity: 5);

var producer = Task.Run(() => {
for (int i = 0; i < 10; i++) {
queue.Add(i); // Blocks if full
Console.WriteLine($"Produced: {i}");
Thread.Sleep(100);  
 }
queue.CompleteAdding(); // Signal no more items
});

// Consumer
var consumer = Task.Run(() => {
foreach (var item in queue.GetConsumingEnumerable()) {
Console.WriteLine($"\tConsumed: {item}");
Thread.Sleep(150);
}
});

````

#### Channel\<T> (async/await)

```csharp
var channel = Channel.CreateUnbounded<int>();

var producer = Task.Run(async () =>
{
    for (int i = 0; i < 10; i++)
    {
        await channel.Writer.WriteAsync(i);
        Console.WriteLine($"Produced: {i}");
        await Task.Delay(100);
    }
    channel.Writer.Complete(); // signal end
});

var consumer = Task.Run(async () =>
{
    await foreach (var item in channel.Reader.ReadAllAsync())
    {
        Console.WriteLine($"\tConsumed: {item}");
        await Task.Delay(150);
    }
});

await Task.WhenAll(producer, consumer);
````

Choose bounded channels for `Wait`, `DropOldest`, etc.
Always call `CompleteAdding()` / `Writer.Complete()`.

---

## Streaming Data using IAsyncEnumerable

```csharp
async IAsyncEnumerable<string> ReadLargeFileAsync(string path)
{
    using var r = File.OpenText(path);
    while (!r.EndOfStream)
        yield return await r.ReadLineAsync();
}

await foreach (var line in ReadLargeFileAsync("log.txt"))
    Process(line);
```

---

## Async-Compatible Initialization

_Interface pattern_

```csharp
interface IAsyncInitializable { Task InitializeAsync(); }
```

_Factory pattern_

```csharp
var svc = await MyService.CreateAsync();
```
