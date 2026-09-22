// frozen_string_literal: true
//
// Native implementation of Riptide::Collector: records which lines of project
// source execute while a block runs. Registers a raw C event hook
// (rb_add_event_hook2 + RUBY_EVENT_HOOK_FLAG_RAW_ARG) rather than a TracePoint, so
// path/line come straight off the rb_trace_arg_t the VM already built to fire the
// event (via rb_tracearg_path/rb_tracearg_lineno), with no Ruby Proc invocation and
// no TracePoint object construction in the hot path -- see riptide's implementation
// plan for the full mechanism trace against Ruby's own vm_trace.c.
//
// Every VALUE this file holds onto across event-hook invocations (root_with_slash,
// scope_cache, touched, last_path, last_relative_or_false, last_array) is an ordinary
// Ruby object (String, Hash, Array), not a raw untracked pointer, specifically so GC
// marking and compaction stay inside Ruby's own object implementations rather than a
// hand-rolled C table. See dmark/dcompact below: each is a one-line delegation.

#include <ruby.h>
#include <ruby/debug.h>

static VALUE mRiptide;
static VALUE cCollector;

// Content-keyed Hash: "<root>/" => a per-root, compare_by_identity Hash mapping a
// file's path VALUE (stable and reused per iseq -- confirmed against rb_iseq_path,
// the same object Coverage itself keys its own results hash by) to either that file's
// precomputed relative-path VALUE (in scope) or Qfalse (out of scope). Lives for the
// whole process: a file's scope membership can't change mid-run, so only the first
// test in the entire suite to touch a given file ever pays the classification cost.
// Keyed by root (not a single flat cache) because direct usage -- this gem's own
// tests included -- creates collectors against different roots in the same process.
static VALUE root_scope_caches;

typedef struct {
    VALUE root_with_slash;
    VALUE scope_cache;
    VALUE touched;
    VALUE last_path;
    VALUE last_relative_or_false;
    VALUE last_array;
    int active;
} riptide_native_collector_t;

static void
riptide_native_collector_mark(void *ptr)
{
    riptide_native_collector_t *data = (riptide_native_collector_t *)ptr;
    rb_gc_mark_movable(data->root_with_slash);
    rb_gc_mark_movable(data->scope_cache);
    rb_gc_mark_movable(data->touched);
    rb_gc_mark_movable(data->last_path);
    rb_gc_mark_movable(data->last_relative_or_false);
    rb_gc_mark_movable(data->last_array);
}

static void
riptide_native_collector_compact(void *ptr)
{
    riptide_native_collector_t *data = (riptide_native_collector_t *)ptr;
    data->root_with_slash = rb_gc_location(data->root_with_slash);
    data->scope_cache = rb_gc_location(data->scope_cache);
    data->touched = rb_gc_location(data->touched);
    data->last_path = rb_gc_location(data->last_path);
    data->last_relative_or_false = rb_gc_location(data->last_relative_or_false);
    data->last_array = rb_gc_location(data->last_array);
}

static void
riptide_native_collector_free(void *ptr)
{
    // Deliberately does not attempt to remove a still-active hook here: dfree
    // receives only the raw data pointer, not the wrapping VALUE, and this VALUE is
    // exactly what rb_add_event_hook2 was given as its `data` argument, needed to
    // find the right hook entry to remove. #start/#stop guard against double-start
    // and are always paired in every real call site (MinitestHooks#stop runs from
    // before_teardown, which Minitest always calls, and #capture always pairs them
    // itself), so a collector reaching dfree while still active means a caller
    // skipped #stop -- a usage bug, not a state this file tries to recover from.
    xfree(ptr);
}

static const rb_data_type_t riptide_native_collector_data_type = {
    "Riptide::Collector",
    {
        riptide_native_collector_mark,
        riptide_native_collector_free,
        NULL,
        riptide_native_collector_compact,
    },
    0,
    0,
    RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE
riptide_native_collector_alloc(VALUE klass)
{
    riptide_native_collector_t *data;
    VALUE obj = TypedData_Make_Struct(klass, riptide_native_collector_t, &riptide_native_collector_data_type, data);

    data->root_with_slash = Qnil;
    data->scope_cache = Qnil;
    data->touched = Qnil;
    data->last_path = Qnil;
    data->last_relative_or_false = Qfalse;
    data->last_array = Qnil;
    data->active = 0;

    return obj;
}

static riptide_native_collector_t *
get_data(VALUE self)
{
    riptide_native_collector_t *data;
    TypedData_Get_Struct(self, riptide_native_collector_t, &riptide_native_collector_data_type, data);
    return data;
}

// root is already File.expand_path'd by the Ruby-level wrapper (lib/riptide/collector.rb).
static VALUE
riptide_native_collector_initialize(VALUE self, VALUE root)
{
    riptide_native_collector_t *data = get_data(self);

    Check_Type(root, T_STRING);

    VALUE root_with_slash = rb_str_plus(root, rb_str_new_cstr("/"));
    rb_str_freeze(root_with_slash);
    data->root_with_slash = root_with_slash;

    VALUE scope_cache = rb_hash_aref(root_scope_caches, root_with_slash);
    if (NIL_P(scope_cache)) {
        scope_cache = rb_hash_new();
        rb_funcall(scope_cache, rb_intern("compare_by_identity"), 0);
        rb_hash_aset(root_scope_caches, root_with_slash, scope_cache);
    }
    data->scope_cache = scope_cache;

    return self;
}

// Classifies `path` (an absolute file path VALUE from rb_tracearg_path) against this
// instance's root, populating the shared scope cache on a miss. Returns the file's
// relative-path VALUE if in scope, Qfalse otherwise. Only runs on a scope-cache miss,
// i.e. at most once per file per root for the life of the process -- not the hot path.
static VALUE
classify(riptide_native_collector_t *data, VALUE path)
{
    VALUE cached = rb_hash_aref(data->scope_cache, path);
    if (!NIL_P(cached)) return cached;

    long root_len = RSTRING_LEN(data->root_with_slash);
    long path_len = RSTRING_LEN(path);
    VALUE result;

    if (path_len > root_len &&
        memcmp(RSTRING_PTR(path), RSTRING_PTR(data->root_with_slash), root_len) == 0) {
        result = rb_str_new(RSTRING_PTR(path) + root_len, path_len - root_len);
        rb_str_freeze(result);
    } else {
        result = Qfalse;
    }

    rb_hash_aset(data->scope_cache, path, result);
    return result;
}

static void
riptide_line_hook(VALUE self, rb_trace_arg_t *trace_arg)
{
    riptide_native_collector_t *data = get_data(self);

    VALUE path = rb_tracearg_path(trace_arg);
    if (NIL_P(path)) return;

    if (path != data->last_path) {
        data->last_path = path;
        data->last_relative_or_false = classify(data, path);

        if (data->last_relative_or_false != Qfalse) {
            VALUE arr = rb_hash_aref(data->touched, data->last_relative_or_false);
            if (NIL_P(arr)) {
                arr = rb_ary_new();
                rb_hash_aset(data->touched, data->last_relative_or_false, arr);
            }
            data->last_array = arr;
        } else {
            data->last_array = Qnil;
        }
    }

    if (data->last_relative_or_false == Qfalse) return;

    VALUE lineno = rb_tracearg_lineno(trace_arg);
    rb_ary_push(data->last_array, lineno);
}

static VALUE
riptide_native_collector_start(VALUE self)
{
    riptide_native_collector_t *data = get_data(self);

    if (data->active) {
        rb_raise(rb_eRuntimeError, "Riptide::Collector#start called while already active; call #stop first");
    }

    VALUE touched = rb_hash_new();
    rb_funcall(touched, rb_intern("compare_by_identity"), 0);
    data->touched = touched;
    data->last_path = Qnil;
    data->last_relative_or_false = Qfalse;
    data->last_array = Qnil;
    data->active = 1;

    rb_add_event_hook2((rb_event_hook_func_t)riptide_line_hook, RUBY_EVENT_LINE, self,
                        RUBY_EVENT_HOOK_FLAG_SAFE | RUBY_EVENT_HOOK_FLAG_RAW_ARG);

    return Qnil;
}

static int
copy_touched_entry(VALUE relative_path, VALUE lines, VALUE result)
{
    VALUE set_class = rb_const_get(rb_cObject, rb_intern("Set"));
    VALUE set = rb_funcall(set_class, rb_intern("new"), 1, lines);
    rb_hash_aset(result, relative_path, set);
    return ST_CONTINUE;
}

static VALUE
riptide_native_collector_stop(VALUE self)
{
    riptide_native_collector_t *data = get_data(self);

    if (!data->active) {
        rb_raise(rb_eRuntimeError, "Riptide::Collector#stop called without an active #start");
    }

    rb_remove_event_hook_with_data((rb_event_hook_func_t)riptide_line_hook, self);
    data->active = 0;

    VALUE result = rb_hash_new();
    rb_hash_foreach(data->touched, copy_touched_entry, result);
    return result;
}

void
Init_riptide_native(void)
{
    mRiptide = rb_define_module("Riptide");
    cCollector = rb_define_class_under(mRiptide, "Collector", rb_cObject);
    rb_define_alloc_func(cCollector, riptide_native_collector_alloc);

    rb_define_private_method(cCollector, "_native_initialize", riptide_native_collector_initialize, 1);
    rb_define_method(cCollector, "start", riptide_native_collector_start, 0);
    rb_define_method(cCollector, "stop", riptide_native_collector_stop, 0);

    root_scope_caches = rb_hash_new();
    rb_gc_register_address(&root_scope_caches);
}
