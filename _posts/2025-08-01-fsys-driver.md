---
layout: post
title: building an in-memory filesystem driver from scratch
date: 2025-08-01
description: let's understand how linux filesystem works and how to write your own
tags: linux, kernel, c
categories: programming

_styles: >
  h2 {
    margin-top: 1em;
    margin-bottom: 1em;
  }

  h4 {
    margin-top: 1em;
  }
---

A file system is what allows us to organize files and directories into hierarchical trees. But how is this actually implemented in Linux?

Following the Feynman's famous quote, we are going to build own in-memory file system driver to understand it. This guide focuses on the practical aspects necessary to get such a filesystem up and running. For a deeper dive, check out the references and the “Further Reading” section at the end.

You can find the source code in this [repo](https://github.com/timofey256/ram-file-system).

## How Do Users Interact with Filesystems?

Your first thought can be: “Through applications, the shell, or tools like `ls` and `vim`.” That’s true but let's go one level deeper, and you'll find system calls.

Whenever a userspace program performs an I/O operation: opening a file, reading data, or writing to disk - it issues a system call such as `open`, `read`, or `write`. These syscalls are the entry points into the kernel.

But how does the kernel handle them? How does it know _where_ in memory to write the data, _how_ to create or delete files, or _which_ filesystem should respond?

We're not going to cover syscall mechanics in this post (you can find excellent [explanations here](https://linux-kernel-labs.github.io/refs/heads/master/lectures/syscalls.html)), but we’ll explore what happens _after_ a syscall hits the kernel — specifically how the Virtual Filesystem (VFS) bridges this gap.

## The Virtual Filesystem (VFS)

The Virtual Filesystem is a component of the kernel that handles all system calls related to files and file systems. Think of it as a universal adapter which allows multiple filesystems (ext4, tmpfs, NFS, your custom driver) to coexist and plug into the same syscall interface. VFS takes care of most of the complex and error-prone parts, like caching, buffer management, and pathname resolution but delegates the actual storage and retrieval to your specific filesystem driver.

<div class="row mt-3">
    <div class="col-sm mt-3 mt-md-0">
        {% include figure.liquid loading="eager" path="assets/img/filesys-driver/vfs-arch.png" class="img-fluid rounded z-depth-1" %}
    </div>
</div>
<div class="caption">
   High-level overview of how VFS works 
</div>

## How Does the VFS Interface Look?

Let’s work from first principles. If you were designing a filesystem interface, you’d want to define:

1. Metadata about the filesystem itself: its name, block size, max filename length, etc.
2. Operations on the filesystem: how to mount it, unmount it, query statistics, etc.

That’s exactly what Linux does using a structure called `file_system_type`.

#### `file_system_type`: Registering a Filesystem

This structure represents a specific type of filesystem (e.g. `ext4`, `tmpfs`, or `myramfs`) and provides the logic for mounting and unmounting it:

```c
struct file_system_type {
    const char *name;
    struct dentry *(*mount)(struct file_system_type *, int, const char *, void *);
    void (*kill_sb)(struct super_block *);
    struct module *owner;
    // ...
};
```

When your driver is loaded, you register this structure with the kernel using `register_filesystem`.

#### Superblock: Mounting a Filesystem

Once a filesystem is registered, how does it get _used_? The answer is: via mounting.

Every mounted instance of a filesystem is represented by a `super_block` structure, which tracks its root directory, all its inodes, and any internal metadata:

```
struct super_block {
    struct list_head s_inodes;   // All inodes in this mount
    struct dentry *s_root;       // Root directory entry
    struct file_system_type *s_type; // Back-pointer to FS driver
    unsigned long s_blocksize;
    unsigned long s_magic;
    const struct super_operations *s_op;
    void *s_fs_info;             // FS-specific data
    // ...
};
```

The superblock esentially answers: “What does this filesystem look like once mounted?”

#### Inode: Representing Files and Directories

Next, we need a way to represent individual files or directories. In Linux, they’re both handled using a structure called an inode.

An inode holds metadata like size, permissions, timestamps, and pointers to file content. But importantly — it **doesn’t** store the filename.

Why not? Because the same inode can have multiple names (hard links), and we don’t want to duplicate the actual file or its metadata. The filename is managed separately, using a `dentry`.

Linux kernel implementation of inode is [here](https://github.com/torvalds/linux/blob/master/fs/ext4/ext4.h#L787).

#### Dentry: Directory Entry

A **dentry** (directory entry) maps a filename to its corresponding inode. You can think of it as the glue between filenames and the actual file content.

<div class="row mt-3">
    <div class="col-sm mt-3 mt-md-0">
        {% include figure.liquid loading="eager" path="assets/img/filesys-driver/dentry-mapping.png" class="img-fluid rounded z-depth-1" %}
    </div>
</div>
<div class="caption">
    Illustration of how dentries map to inodes. 
</div>

Multiple dentries can point to the same inode (e.g., via `ln file linkname`), enabling hard links without data duplication. You can inspect inode numbers with `ls -i`:

```bash
$ touch file
$ ln file link
$ ls -i
```

Example output:

```
49020997 file
49020997 link
```

Here’s a how dentry looks like in [Linux kernel source code](https://elixir.bootlin.com/linux/v6.16/source/include/linux/dcache.h#L92):

```
struct dentry {
    //...
    struct inode             *d_inode;     /* associated inode */
    //...
    struct dentry            *d_parent;    /* dentry object of parent */
    struct qstr              d_name;       /* dentry name */
    //...

    struct dentry_operations *d_op;        /* dentry operations table */
    struct super_block       *d_sb;        /* superblock of file */
    void                     *d_fsdata;    /* filesystem-specific data */
    //...
};
```

#### `struct file`: Open File Instances

When a file is opened (via `open()` syscall), the kernel creates a `struct file` instance. It tracks:

- The current offset (`f_pos`)
- Flags like read/write mode
- A pointer to the file’s operations (read, write, seek, etc.)
- A pointer to the inode and private data

This is what gets passed to your `read`, `write`, and `ioctl` handlers.

#### How it all interacts together?

Here’s how everything connects:

<div class="row mt-3">
    <div class="col-sm mt-3 mt-md-0">
        {% include figure.liquid loading="eager" path="assets/img/filesys-driver/ds-structure.png" class="img-fluid rounded z-depth-1" %}
    </div>
</div>
<div class="caption">
    How different data structures are linked together.
</div>

## Implementation: define file system and its superblock

Now we can start implementing our filesystem driver. We'll begin from scratch by defining the file system type:

```c
static const struct super_operations rf_sops = {
    .statfs      = simple_statfs,  // default function from lib
    .drop_inode  = generic_delete_inode, // default function from lib
    .evict_inode = rf_evict // custom function; see implementation in the source
};

static int rf_fill_super(struct super_block *sb, void *data, int silent)
{
    sb->s_op = &rf_sops;
    sb->s_magic = RAMFSC_MAGIC;
    sb->s_time_gran = 1;

    // initialize root directory
    struct inode *root;
    root = rf_make_inode(sb, S_IFDIR | 0755); // custom function
    if (!root)
        return -ENOMEM;
    root->i_op = &rf_dir_iops;

    sb->s_root = d_make_root(root);
    if (!sb->s_root)
        return -ENOMEM;

    return 0;
}

static struct dentry *rf_mount(struct file_system_type *t,
                               int flags, const char *dev, void *data)
{
    return mount_nodev(t, flags, data, rf_fill_super);
}

static struct file_system_type rf_fs_type = {
    .owner   = THIS_MODULE,
    .name    = "myramfs",
    .mount   = rf_mount,
    .kill_sb = kill_litter_super,
};

static int __init rf_init(void)   { return register_filesystem(&rf_fs_type); }
static void __exit rf_exit(void)  { unregister_filesystem(&rf_fs_type); }
```

The VFS provides two functions for registering and unregistering a filesystem: `register_filesystem` and `unregister_filesystem`. Both accept a `file_system_type` structure, which defines the owner, the name of the driver (remember this—we'll use it when mounting later!), and two function pointers invoked during mount and unmount operations, respectively.

Let’s examine those functions more closely. `rf_mount` is called during the mounting process. It simply delegates to the standard `mount_nodev`, which initializes the superblock and then calls `rf_fill_super` to finish the setup.

`rf_fill_super` performs two main tasks: it completes the superblock initialization and attaches the root directory to it.

## How to operate under `root`?

`root` is a directory, so we need to define how to look up files, create new files, and create subdirectories under it. All of this is specified in `rf_dir_iops` (remember how we assigned it when creating the root inode?). Let's take a closer look:

```c
static const struct inode_operations rf_dir_iops = {
    .lookup = simple_lookup,
    .create = rf_create,
    .setattr = rf_setattr,
    .mkdir = rf_mkdir,
};
```

For now, we define just four operations:

- `lookup`: a default VFS function used to resolve names to dentries.
- `create`: used to create regular files.
- `setattr`: used internally by the VFS to set inode attributes.
- `mkdir`: used to create directories.

Let’s walk through each of these:

```c
static int rf_create(struct mnt_idmap *idmap, struct inode *dir,
                     struct dentry *dentry, umode_t mode, bool excl) {
    struct inode *ino = rf_make_inode(dir->i_sb, S_IFREG | mode);
    struct rbuf  *rb;

    if (!ino)
        return -ENOMEM;

    rb = kzalloc(sizeof(*rb), GFP_KERNEL);
    if (!rb || rf_reserve(rb, PAGE_SIZE)) {
        iput(ino);
        kfree(rb);
        return -ENOMEM;
    }
    ino->i_private = rb;

    d_add(dentry, ino);   // bind dentry to inode
    return 0;
}
```

When creating a new file, the VFS calls `rf_create`. The steps are:

1. Allocate an inode — the core structure holding file metadata.
2. Since the file will store data, allocate a buffer. We use a simple in-memory buffer type, `rbuf`:

```c
/* File RAM buffer */
struct rbuf {
    char  *data;
    size_t size;      // bytes used
    size_t cap;       // bytes allocated
};
```

This is an in-memory filesystem, so we don’t care about persistence. The buffer is allocated using `rf_reserve`, which is essentially a wrapper around `malloc` — see the source for details.

Once memory is allocated, we link the inode to the dentry using `d_add`. Now, to the new directories.

```c
static int rf_mkdir(struct mnt_idmap *idmap, struct inode *dir,
                    struct dentry *dentry, umode_t mode)
{
    struct inode *inode;

    inode = rf_make_inode(dir->i_sb, S_IFDIR | mode);
    if (!inode)
        return -ENOMEM;

    inode_inc_link_count(dir);
    inode_inc_link_count(inode);

    inode->i_op  = &rf_dir_iops;
    inode->i_fop = &simple_dir_operations;

    d_add(dentry, inode);

    return 0;
}
```

This follows the same basic flow as `rf_create`, with one key addition: the two calls to `inode_inc_link_count`.

What’s happening here?

- `inode_inc_link_count(inode)` handles the `"."` link: every directory contains a reference to itself.
- `inode_inc_link_count(dir)` accounts for the `".."` link: the new directory will reference its parent, and the parent now contains one more subdirectory.

This mirrors how UNIX filesystems track directory link counts — each subdirectory increases its parent’s link count by 1.

I’m skipping `rf_setattr` here for simplicity. You can check out the implementation in the source.

## But how did we allocate inode?

When we were creating new files and directories, you may have noticed that the actual allocation of the inode happened somewhere else. In `rf_create` and `rf_mkdir`, we simply called `rf_make_inode`, then added custom metadata or attached buffers. So how was the inode actually allocated?

The answer: `rf_make_inode` is just a thin wrapper around `new_inode`.

```c
static struct inode *rf_make_inode(struct super_block *sb, umode_t mode)
{
    struct inode *inode = new_inode(sb);
    if (!inode)
        return NULL;

    inode_init_owner(&nop_mnt_idmap, inode, NULL, mode);

    if (S_ISDIR(mode)) {
        inode->i_op  = &simple_dir_inode_operations;
        inode->i_fop = &simple_dir_operations;
    } else {
        inode->i_fop = &rf_fops;
        inode->i_mapping->a_ops = &empty_aops;
    }
    return inode;
}
```

Based on the mode, we check if this inode represents a directory. If it’s a directory, we assign it default directory operations via `simple_dir_inode_operations` and `simple_dir_operations`. If it’s a regular file, we assign it our own `rf_fops` for file operations and configure the address space operations (`a_ops`) using `empty_aops`. This disables any page-level caching or backing store because we're working purely in memory.

## Finally, File Manipulations!

Naturally, we want to be able to read from and write to the inodes we've created. Let's define the appropriate file operations.

```c
static const struct file_operations rf_fops = {
    .open    = rf_open,
    .read    = rf_read,
    .write   = rf_write,
    .llseek  = generic_file_llseek,
    .fsync   = rf_fsync,
};
```

#### `rf_open`

When a file is opened, we simply attach its associated buffer (stored in the inode) to the file’s private data:

```c
static int rf_open(struct inode *inode, struct file *filp)
{
    filp->private_data = inode->i_private;
    return 0;
}
```

#### `rf_read`

To read from a file, we copy data from our in-memory buffer to user space. The buffer is retrieved from `filp->private_data`, which we set in `rf_open`:

```c
static ssize_t rf_read(struct file *f, char __user *buf,
                       size_t len, loff_t *ppos)
{
    struct rbuf *rb = f->private_data;
    return simple_read_from_buffer(buf, len, ppos, rb->data, rb->size);
}
```

This delegates to a kernel helper that handles offset tracking and boundary checking.

#### `rf_write`

Writing is slightly more involved, but still straightforward. We:

1. Retrieve our buffer from `private_data`.
2. Check whether the file is opened in append mode.
3. Calculate the new end offset.
4. Reserve enough space in the buffer.
5. Copy data from user space.
6. Update the offset, buffer size, and inode size.

```c
static ssize_t rf_write(struct file *f, const char __user *buf,
                        size_t len, loff_t *ppos)
{
    struct rbuf *rb = f->private_data;

    if (f->f_flags & O_APPEND)
        *ppos = rb->size;

    loff_t end = *ppos + len;

    if (end > INT_MAX) // sanity check
        return -EFBIG;
    if (rf_reserve(rb, end))
        return -ENOMEM;
    if (copy_from_user(rb->data + *ppos, buf, len))
        return -EFAULT;

    *ppos += len;
    rb->size = max_t(size_t, rb->size, end);
    i_size_write(file_inode(f), rb->size); // updates inode's size
    return len;
}
```

#### `fsync`

If you open a file in `vim` and try to save it, the editor will call the `fsync` syscall to flush file contents to disk. If `fsync` is unimplemented, this operation would fail. Since we're building an in-memory filesystem, there's nothing to flush. But we still need to handle the call:

```c
static int rf_fsync(struct file *file, loff_t start, loff_t end, int datasync)
{
    return 0;
}
```

## Further reading

- [Linux kernel labs: Filesystem Management](https://linux-kernel-labs.github.io/refs/heads/master/lectures/fs.html) - excellent notes describing Linux Filesystem Management.
- [Linux kernel labs: Filesystem drivers (Part 1)](https://linux-kernel-labs.github.io/refs/heads/master/labs/filesystems_part1.html) - check out their labs on drivers too!
- [Creating Linux virtual filesystems](https://lwn.net/Articles/57369/) - older but very simple guide on basic filesys driver.
- [Longer guide on writing Linux Kernel modules](https://sysprog21.github.io/lkmpg/).
- [The Linux Kernel](https://aeb.win.tue.nl/linux/lk/lk-8.html) by Andries Brouwer.
- [Some chinese blogpost where I took diagrams from](https://nano-chicken.blogspot.com/2020/05/linux-kernel181-my-first-filesystem.html).
