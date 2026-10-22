// Riptide::Tracer: one hook for the life of the process. Every in-scope line,
// method entry and block entry goes to the open test window, or to load facts
// while its thread is inside a class body, or else to boot lines.

#include <ruby.h>
#include <ruby/debug.h>
#include <ruby/encoding.h>

static VALUE mRiptide;
static VALUE mTracer;

static VALUE roots = Qnil;         // the root with a trailing slash, and its realpath if that differs
static VALUE scope_cache = Qnil;   // path VALUE => relative path String, or false
#define SCOPE_CACHE_LIMIT 100000     // eval makes a new path string every time
static VALUE stacks = Qnil;        // thread => [class, frame depth, ...] being defined
static long loading = 0;           // classes being defined, summed over threads

static VALUE window = Qnil;        // relative path => byte map String, or nil
static VALUE receivers = Qnil;     // class => true for each receiver of an in-scope method in the window
static VALUE last_receiver = Qnil;
static VALUE load_facts = Qnil;    // relative path => { line => Array of classes }
static VALUE load_called = Qnil;   // relative path => { line => true } for called code
static VALUE owner_files = Qnil;   // class => { relative path => true }
static VALUE boot_lines = Qnil;    // relative path => { line => true }

static VALUE last_path = Qnil;
static VALUE last_relative = Qfalse;
static VALUE last_map = Qnil;

static int installed = 0;

static VALUE
identity_hash(void)
{
    VALUE hash = rb_hash_new();
    rb_funcall(hash, rb_intern("compare_by_identity"), 0);
    return hash;
}

static VALUE
relative_path(VALUE path)
{
    if (path == last_path) return last_relative;

    VALUE cached = rb_hash_lookup2(scope_cache, path, Qundef);
    if (cached == Qundef) {
        if (RHASH_SIZE(scope_cache) >= SCOPE_CACHE_LIMIT) rb_hash_clear(scope_cache);
        cached = Qfalse;
        long path_len = RSTRING_LEN(path);
        for (long i = 0; i < RARRAY_LEN(roots); i++) {
            VALUE root = rb_ary_entry(roots, i);
            long root_len = RSTRING_LEN(root);
            if (path_len > root_len && memcmp(RSTRING_PTR(path), RSTRING_PTR(root), root_len) == 0) {
                cached = rb_enc_str_new(RSTRING_PTR(path) + root_len, path_len - root_len, rb_enc_get(path));
                rb_str_freeze(cached);
                break;
            }
        }
        rb_hash_aset(scope_cache, path, cached);
    }

    last_path = path;
    last_relative = cached;
    last_map = Qnil;
    return cached;
}

static VALUE
current_stack(int create)
{
    VALUE thread = rb_thread_current();
    VALUE stack = rb_hash_lookup2(stacks, thread, Qnil);
    if (NIL_P(stack) && create) {
        stack = rb_ary_new();
        rb_hash_aset(stacks, thread, stack);
    }
    return stack;
}

static void
nested_set(VALUE outer, VALUE key, VALUE inner_key)
{
    VALUE inner = rb_hash_lookup2(outer, key, Qnil);
    if (NIL_P(inner)) {
        inner = rb_hash_new();
        rb_hash_aset(outer, key, inner);
    }
    rb_hash_aset(inner, inner_key, Qtrue);
}

// Frames on the current thread's stack. Only counted on class entry and on
// a rescue while a class is loading, both rare.
#define MAX_DEPTH 65536
static VALUE frame_buffer[MAX_DEPTH];
static int line_buffer[MAX_DEPTH];

static long
frame_depth(void)
{
    return rb_profile_frames(0, MAX_DEPTH, frame_buffer, line_buffer);
}

static VALUE
current_owner(VALUE stack)
{
    return rb_ary_entry(stack, -2);
}

static void
pop_owner(VALUE stack)
{
    rb_ary_pop(stack);
    rb_ary_pop(stack);
    loading--;
    if (RARRAY_LEN(stack) == 0) rb_hash_delete(stacks, rb_thread_current());
}

// `class << obj` on a plain object opens a class nothing else will ever
// name, so it's tracked for loading but never kept as an owner.
static void
on_class(VALUE klass, VALUE path)
{
    VALUE stack = current_stack(1);
    rb_ary_push(stack, klass);
    rb_ary_push(stack, LONG2FIX(frame_depth()));
    loading++;

    if (RB_TYPE_P(klass, T_CLASS) && FL_TEST(klass, FL_SINGLETON)) {
        VALUE attached = rb_class_attached_object(klass);
        if (!RB_TYPE_P(attached, T_CLASS) && !RB_TYPE_P(attached, T_MODULE)) return;
    }

    VALUE relative = NIL_P(path) ? Qfalse : relative_path(path);
    if (relative != Qfalse) nested_set(owner_files, klass, relative);
}

static void
on_end(void)
{
    VALUE stack = current_stack(0);
    if (NIL_P(stack) || RARRAY_LEN(stack) == 0) return;

    pop_owner(stack);
}

// A class body that raises never reaches its end event. Once something
// shallower rescues the error, the bodies it unwound are done loading.
static void
on_rescue(void)
{
    VALUE stack = current_stack(0);
    if (NIL_P(stack) || RARRAY_LEN(stack) == 0) return;

    long depth = frame_depth();
    while (RARRAY_LEN(stack) > 0 && FIX2LONG(rb_ary_entry(stack, -1)) > depth) pop_owner(stack);
}

// Whether the running frame is a method or block, not a class or module body.
static int
in_called_code(void)
{
    VALUE frame;
    int line;
    if (rb_profile_frames(0, 1, &frame, &line) < 1) return 0;

    VALUE label = rb_profile_frame_label(frame);
    if (NIL_P(label)) return 0;

    const char *text = RSTRING_PTR(label);
    long len = RSTRING_LEN(label);
    if (len >= 7 && strncmp(text, "<class:", 7) == 0) return 0;
    if (len >= 8 && strncmp(text, "<module:", 8) == 0) return 0;
    if (len >= 15 && strncmp(text, "singleton class", 15) == 0) return 0;
    return 1;
}

static void
record_load(VALUE relative, VALUE owner, VALUE lineno)
{
    if (in_called_code()) nested_set(load_called, relative, lineno);

    VALUE lines = rb_hash_lookup2(load_facts, relative, Qnil);
    if (NIL_P(lines)) {
        lines = rb_hash_new();
        rb_hash_aset(load_facts, relative, lines);
    }
    VALUE owners = rb_hash_lookup2(lines, lineno, Qnil);
    if (NIL_P(owners)) {
        owners = rb_ary_new();
        rb_hash_aset(lines, lineno, owners);
    }
    if (!RTEST(rb_ary_includes(owners, owner))) rb_ary_push(owners, owner);
    nested_set(owner_files, owner, relative);
}

static void
record_window(VALUE relative, long line)
{
    if (NIL_P(last_map)) {
        last_map = rb_hash_lookup2(window, relative, Qnil);
        if (NIL_P(last_map)) {
            last_map = rb_str_new(NULL, 256);
            memset(RSTRING_PTR(last_map), 0, 256);
            rb_hash_aset(window, relative, last_map);
        }
    }

    long len = RSTRING_LEN(last_map);
    if (line >= len) {
        long grown = line * 2 + 1;
        rb_str_resize(last_map, grown);
        memset(RSTRING_PTR(last_map) + len, 0, grown - len);
    }
    RSTRING_PTR(last_map)[line] = 1;
}

static void
hook(VALUE data, rb_trace_arg_t *arg)
{
    (void)data;
    rb_event_flag_t event = rb_tracearg_event_flag(arg);

    if (event == RUBY_EVENT_CLASS) {
        on_class(rb_tracearg_self(arg), rb_tracearg_path(arg));
        return;
    }
    if (event == RUBY_EVENT_END) {
        on_end();
        return;
    }
    if (event == RUBY_EVENT_RESCUE) {
        if (loading > 0) on_rescue();
        return;
    }

    VALUE path = rb_tracearg_path(arg);
    if (NIL_P(path)) return;

    VALUE relative = relative_path(path);
    if (relative == Qfalse) return;

    VALUE lineno = rb_tracearg_lineno(arg);

    if (loading > 0) {
        VALUE stack = current_stack(0);
        if (!NIL_P(stack) && RARRAY_LEN(stack) > 0) {
            record_load(relative, current_owner(stack), lineno);
            return;
        }
    }

    if (!NIL_P(window)) {
        record_window(relative, FIX2LONG(lineno));
        if (event == RUBY_EVENT_CALL) {
            // A method that comes in later anywhere in the receiver's
            // ancestry can take this call over, so the receiver's class
            // counts, not just where the method lives.
            // A class method's receiver is the class itself, whose
            // singleton ancestry riptide expands later.
            VALUE self = rb_tracearg_self(arg);
            VALUE klass = RB_TYPE_P(self, T_CLASS) || RB_TYPE_P(self, T_MODULE) ? self : rb_obj_class(self);
            if (klass != last_receiver) {
                last_receiver = klass;
                rb_hash_aset(receivers, klass, Qtrue);
            }
        }
    } else {
        nested_set(boot_lines, relative, lineno);
    }
}

static VALUE
tracer_install(VALUE self, VALUE prefixes)
{
    (void)self;
    Check_Type(prefixes, T_ARRAY);
    if (installed) rb_raise(rb_eRuntimeError, "Riptide::Tracer is already installed");

    roots = rb_ary_freeze(rb_ary_dup(prefixes));
    installed = 1;
    rb_add_event_hook2((rb_event_hook_func_t)hook, RUBY_EVENT_LINE | RUBY_EVENT_CALL | RUBY_EVENT_B_CALL | RUBY_EVENT_CLASS | RUBY_EVENT_END | RUBY_EVENT_RESCUE, Qnil,
                       RUBY_EVENT_HOOK_FLAG_SAFE | RUBY_EVENT_HOOK_FLAG_RAW_ARG);
    return Qnil;
}

static VALUE
tracer_installed_p(VALUE self)
{
    (void)self;
    return installed ? Qtrue : Qfalse;
}

static VALUE
tracer_open_window(VALUE self)
{
    (void)self;
    if (!NIL_P(window)) rb_raise(rb_eRuntimeError, "a Riptide::Tracer window is already open");

    window = rb_hash_new();
    receivers = identity_hash();
    last_map = Qnil;
    last_receiver = Qnil;
    return Qnil;
}

static int
collect_lines(VALUE relative, VALUE map, VALUE result)
{
    const char *bytes = RSTRING_PTR(map);
    long len = RSTRING_LEN(map);
    VALUE lines = rb_ary_new();
    for (long i = 0; i < len; i++) {
        if (bytes[i]) rb_ary_push(lines, LONG2FIX(i));
    }
    rb_hash_aset(result, relative, lines);
    return ST_CONTINUE;
}

static VALUE
tracer_close_window(VALUE self)
{
    (void)self;
    if (NIL_P(window)) rb_raise(rb_eRuntimeError, "no Riptide::Tracer window is open");

    VALUE lines = rb_hash_new();
    rb_hash_foreach(window, collect_lines, lines);
    VALUE result = rb_assoc_new(lines, rb_funcall(receivers, rb_intern("keys"), 0));
    window = Qnil;
    receivers = Qnil;
    last_map = Qnil;
    last_receiver = Qnil;
    return result;
}

static VALUE
drain(VALUE *slot)
{
    VALUE drained = *slot;
    *slot = rb_hash_new();
    return drained;
}

static VALUE
tracer_drain_load_facts(VALUE self)
{
    (void)self;
    return drain(&load_facts);
}

static VALUE
tracer_drain_load_called(VALUE self)
{
    (void)self;
    return drain(&load_called);
}

static VALUE
tracer_drain_boot_lines(VALUE self)
{
    (void)self;
    return drain(&boot_lines);
}

static VALUE
tracer_owner_files(VALUE self)
{
    (void)self;
    return owner_files;
}

void
Init_riptide_native(void)
{
    mRiptide = rb_define_module("Riptide");
    mTracer = rb_define_module_under(mRiptide, "Tracer");

    scope_cache = identity_hash();
    stacks = identity_hash();
    load_facts = rb_hash_new();
    load_called = rb_hash_new();
    owner_files = identity_hash();
    boot_lines = rb_hash_new();

    rb_gc_register_address(&roots);
    rb_gc_register_address(&scope_cache);
    rb_gc_register_address(&stacks);
    rb_gc_register_address(&window);
    rb_gc_register_address(&receivers);
    rb_gc_register_address(&last_receiver);
    rb_gc_register_address(&load_facts);
    rb_gc_register_address(&load_called);
    rb_gc_register_address(&owner_files);
    rb_gc_register_address(&boot_lines);
    rb_gc_register_address(&last_path);
    rb_gc_register_address(&last_relative);
    rb_gc_register_address(&last_map);

    rb_define_singleton_method(mTracer, "_install", tracer_install, 1);
    rb_define_singleton_method(mTracer, "installed?", tracer_installed_p, 0);
    rb_define_singleton_method(mTracer, "open_window", tracer_open_window, 0);
    rb_define_singleton_method(mTracer, "_close_window", tracer_close_window, 0);
    rb_define_singleton_method(mTracer, "_drain_load_facts", tracer_drain_load_facts, 0);
    rb_define_singleton_method(mTracer, "_drain_load_called", tracer_drain_load_called, 0);
    rb_define_singleton_method(mTracer, "drain_boot_lines", tracer_drain_boot_lines, 0);
    rb_define_singleton_method(mTracer, "_owner_files", tracer_owner_files, 0);
}
