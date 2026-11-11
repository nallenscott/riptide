// Riptide::Tracer. Probes sit on the VM's own trace instructions in the app's
// code and nowhere else, each instruction sequence with a hook list of its
// own, so Rails and gems run untraced and YJIT keeps its compiled code. A line
// probe turns itself off after its first hit and comes back when the next
// test starts, so a test pays once per distinct line it runs, however hot the
// line is. Method, block and class entries and class ends stay armed: they
// record receivers and load facts, and they're where YJIT would otherwise
// jump into app code that a probe coming back later can't reach.
//
// Every in-scope line, method entry and block entry goes to the open test
// window, or to load facts while its thread is inside a class body, or else
// to boot lines.
//
// Hooks this close to the VM need Ruby's internal headers, vendored per
// version under ruby/. On a Ruby without them the tracer says so and riptide
// records nothing.

#ifndef RIPTIDE_UNSUPPORTED

#include "vm_core.h"
#include "iseq.h"
#include "ractor_core.h"
#include "ruby/debug.h"

// Words per instruction, by opcode.
extern const uint8_t rb_vm_insn_len_info[];

static VALUE mRiptide;
static VALUE mTracer;

static VALUE stacks = Qnil;        // thread => [class, frame depth, ...] being defined
static long loading = 0;           // classes being defined, summed over threads

static VALUE window = Qnil;        // relative path => byte map String, or nil
static VALUE receivers = Qnil;     // class => true for each receiver of an in-scope method in the window
static VALUE last_receiver = Qnil;
static VALUE load_facts = Qnil;    // relative path => { line => Array of classes }
static VALUE load_called = Qnil;   // relative path => { line => true } for called code
static VALUE owner_files = Qnil;   // class => { relative path => true }
static VALUE boot_lines = Qnil;    // relative path => { line => true }

static VALUE last_relative = Qnil;
static VALUE last_map = Qnil;
static VALUE last_pinned = Qnil;

static int installed = 0;

#define EVENTS (RUBY_EVENT_LINE | RUBY_EVENT_CALL | RUBY_EVENT_B_CALL | RUBY_EVENT_CLASS | RUBY_EVENT_END)
#define ENTRIES (RUBY_EVENT_CALL | RUBY_EVENT_B_CALL | RUBY_EVENT_CLASS)

// Ruby keeps this one to vm_trace.c.
typedef struct rb_event_hook_struct {
    rb_event_hook_flag_t hook_flags;
    rb_event_flag_t events;
    rb_event_hook_func_t func;
    VALUE data;
    struct rb_event_hook_struct *next;
    struct {
        rb_thread_t *th;
        unsigned int target_line;
    } filter;
} hook_t;

// The probes in one instruction sequence, sorted by pc.
typedef struct {
    const rb_iseq_t *iseq;
    VALUE relative;
    int class_body;
    unsigned int count;
    unsigned int *pc;
    int *line;
    rb_event_flag_t *events;       // everything the VM has at the pc, not just ours
    VALUE *plain;                  // the instruction untraced, or 0 for a probe that stays armed
} probes_t;

// Line probes that went off, to turn back on when the next test starts.
static VALUE **rearm_at;
static VALUE *rearm_word;
static long rearm_len, rearm_cap;

static void
push_rearm(VALUE *at, VALUE word)
{
    if (rearm_len == rearm_cap) {
        rearm_cap = rearm_cap ? rearm_cap * 2 : 4096;
        REALLOC_N(rearm_at, VALUE *, rearm_cap);
        REALLOC_N(rearm_word, VALUE, rearm_cap);
    }
    rearm_at[rearm_len] = at;
    rearm_word[rearm_len] = word;
    rearm_len++;
}

static void
rearm(void)
{
    for (long i = 0; i < rearm_len; i++) *rearm_at[i] = rearm_word[i];
    rearm_len = 0;
}

static VALUE
identity_hash(void)
{
    VALUE hash = rb_hash_new();
    rb_funcall(hash, rb_intern("compare_by_identity"), 0);
    return hash;
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

// Frames on the hooked thread's stack, deeper is bigger.
static long
frame_depth(rb_trace_arg_t *arg)
{
    return RUBY_VM_END_CONTROL_FRAME(arg->ec) - arg->cfp;
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
// name, so it's tracked for loading but never kept as an owner. Lines that
// already went off come back first, so everything the class body runs is a
// load fact, even code the test ran before.
static void
on_class(VALUE klass, VALUE relative, long depth)
{
    if (loading == 0) rearm();

    VALUE stack = current_stack(1);
    rb_ary_push(stack, klass);
    rb_ary_push(stack, LONG2FIX(depth));
    loading++;

    if (RB_TYPE_P(klass, T_CLASS) && FL_TEST(klass, FL_SINGLETON)) {
        VALUE attached = rb_class_attached_object(klass);
        if (!RB_TYPE_P(attached, T_CLASS) && !RB_TYPE_P(attached, T_MODULE)) return;
    }

    nested_set(owner_files, klass, relative);
}

static void
on_end(void)
{
    VALUE stack = current_stack(0);
    if (NIL_P(stack) || RARRAY_LEN(stack) == 0) return;

    pop_owner(stack);
}

// A class body that raises never reaches its end event. Once something
// shallower rescues the error, the bodies it unwound are done loading. The
// rescue clause runs a frame below the one that rescued, so every body at or
// below its depth was unwound.
static void
on_rescue(long depth)
{
    VALUE stack = current_stack(0);
    if (NIL_P(stack) || RARRAY_LEN(stack) == 0) return;

    while (RARRAY_LEN(stack) > 0 && FIX2LONG(rb_ary_entry(stack, -1)) >= depth) pop_owner(stack);
}

static void
record_load(VALUE relative, VALUE owner, VALUE lineno, int called)
{
    if (called) nested_set(load_called, relative, lineno);

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
    if (relative != last_relative) {
        last_relative = relative;
        last_map = Qnil;
    }
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

static long
find_probe(const probes_t *probes, unsigned int pc)
{
    long low = 0, high = (long)probes->count - 1;
    while (low <= high) {
        long mid = (low + high) / 2;
        if (probes->pc[mid] == pc) return mid;
        if (probes->pc[mid] < pc) low = mid + 1;
        else high = mid - 1;
    }
    return -1;
}

static void
hook(VALUE data, rb_trace_arg_t *arg)
{
    probes_t *probes = (probes_t *)(data & ~(VALUE)RUBY_FIXNUM_FLAG);
    rb_event_flag_t event = arg->event;

    if (event == RUBY_EVENT_CLASS) {
        on_class(arg->self, probes->relative, frame_depth(arg));
        return;
    }
    if (event == RUBY_EVENT_END) {
        on_end();
        return;
    }

    // The VM moves the pc one word past the trace instruction while hooks run.
    VALUE *encoded = (VALUE *)ISEQ_BODY(probes->iseq)->iseq_encoded;
    unsigned int pc = (unsigned int)(arg->cfp->pc - encoded) - 1;
    long i = find_probe(probes, pc);
    if (i < 0) return;

    // An entry is on the line it starts at, the def or the block's opening.
    int line = event & ENTRIES ? ISEQ_BODY(probes->iseq)->location.first_lineno : probes->line[i];
    VALUE lineno = INT2FIX(line);

    if (loading > 0) {
        VALUE stack = current_stack(0);
        if (!NIL_P(stack) && RARRAY_LEN(stack) > 0) {
            record_load(probes->relative, current_owner(stack), lineno, !probes->class_body);
            return;
        }
    }

    if (!NIL_P(window)) {
        record_window(probes->relative, line);
        if (event == RUBY_EVENT_CALL) {
            // A method that comes in later anywhere in the receiver's
            // ancestry can take this call over, so the receiver's class
            // counts, not just where the method lives.
            // A class method's receiver is the class itself, whose
            // singleton ancestry riptide expands later.
            VALUE self = arg->self;
            VALUE klass = RB_TYPE_P(self, T_CLASS) || RB_TYPE_P(self, T_MODULE) ? self : rb_obj_class(self);
            if (klass != last_receiver) {
                last_receiver = klass;
                rb_hash_aset(receivers, klass, Qtrue);
            }
        }
    }
    else {
        nested_set(boot_lines, probes->relative, lineno);
    }

    // A global hook on this pc, like coverage or a debugger, needs it traced.
    if (event == RUBY_EVENT_LINE && probes->plain[i] && !(probes->iseq->aux.exec.global_trace_events & probes->events[i])) {
        VALUE *at = &encoded[pc];
        push_rearm(at, *at);
        *at = probes->plain[i];
    }
}

static void
rescue_hook(VALUE data, rb_trace_arg_t *arg)
{
    (void)data;
    if (loading > 0) on_rescue(frame_depth(arg));
}

static rb_ractor_t *
current_ractor(void)
{
    return ((rb_thread_t *)RTYPEDDATA_GET_DATA(rb_thread_current()))->ractor;
}

static VALUE
tracer_install(VALUE self)
{
    (void)self;
    if (installed) rb_raise(rb_eRuntimeError, "Riptide::Tracer is already installed");

    installed = 1;
    // The VM only looks for hook lists on instruction sequences while this
    // is above zero. Targeted TracePoints count it up and down around ours.
    current_ractor()->pub.targeted_hooks_cnt++;
    // A class body that raises is usually rescued outside the app, so
    // rescues are heard everywhere. They're rare enough to cost nothing.
    rb_add_event_hook2((rb_event_hook_func_t)rescue_hook, RUBY_EVENT_RESCUE, Qnil, RUBY_EVENT_HOOK_FLAG_SAFE | RUBY_EVENT_HOOK_FLAG_RAW_ARG);
    return Qnil;
}

// Ruby keeps the succinct index from pc to instruction info to iseq.c.
#define IMMEDIATE_TABLE_SIZE 54
struct succ_index_table {
    uint64_t imm_part[IMMEDIATE_TABLE_SIZE / 9];
    struct succ_dict_block {
        unsigned int rank;
        uint64_t small_block_ranks;
        uint64_t bits[512/64];
    } succ_part[FLEX_ARY_LEN];
};
#define imm_block_rank_get(v, i) (((int)((v) >> ((i) * 7))) & 0x7f)

// Where each instruction info entry starts, worked out the way iseq.c's
// succ_index_table_invert does it.
static unsigned int *
info_positions(const struct rb_iseq_constant_body *body)
{
    int size = (int)body->insns_info.size;
    int max_pos = (int)body->iseq_size;
    unsigned int *positions = ALLOC_N(unsigned int, size);
    if (body->insns_info.positions) {
        MEMCPY(positions, body->insns_info.positions, unsigned int, size);
        return positions;
    }

    const struct succ_index_table *sd = body->insns_info.succ_index_table;
    const int imm_size = (max_pos < IMMEDIATE_TABLE_SIZE ? max_pos + 8 : IMMEDIATE_TABLE_SIZE) / 9;
    const int succ_size = (max_pos < IMMEDIATE_TABLE_SIZE ? 0 : (max_pos - IMMEDIATE_TABLE_SIZE + 511)) / 512;
    unsigned int *p = positions;
    int r = -1;
    for (int j = 0; j < imm_size; j++) {
        for (int i = 0; i < 9; i++) {
            int nr = imm_block_rank_get(sd->imm_part[j], i);
            if (r != nr) *p++ = j * 9 + i;
            r = nr;
        }
    }
    for (int k = 0; k < succ_size; k++) {
        for (int j = 0; j < 8; j++) {
            for (int i = 0; i < 64; i++) {
                if (sd->succ_part[k].bits[j] & (((uint64_t)1) << i)) *p++ = k * 512 + j * 64 + i + IMMEDIATE_TABLE_SIZE;
            }
        }
    }
    return positions;
}

static void
free_probes(probes_t *probes)
{
    ruby_xfree(probes->pc);
    ruby_xfree(probes->line);
    ruby_xfree(probes->events);
    ruby_xfree(probes->plain);
    ruby_xfree(probes);
}

// Finds every pc the tracer cares about, the way the VM decides what to
// trace: each instruction takes the events of the info entry it falls in.
static probes_t *
find_probes(const rb_iseq_t *iseq)
{
    const struct rb_iseq_constant_body *body = ISEQ_BODY(iseq);
    unsigned int info_size = body->insns_info.size;
    if (info_size == 0) return NULL;

    probes_t *probes = ZALLOC(probes_t);
    probes->iseq = iseq;
    probes->class_body = body->type == ISEQ_TYPE_CLASS;
    probes->pc = ALLOC_N(unsigned int, info_size);
    probes->line = ALLOC_N(int, info_size);
    probes->events = ALLOC_N(rb_event_flag_t, info_size);
    probes->plain = ALLOC_N(VALUE, info_size);
    unsigned int capacity = info_size;

    unsigned int *positions = info_size > 1 ? info_positions(body) : NULL;
    int had_original = ISEQ_ORIGINAL_ISEQ(iseq) != NULL;
    const VALUE *code = rb_iseq_original_iseq(iseq);
    unsigned int entry = 0;
    for (unsigned int pc = 0; pc < body->iseq_size; pc += rb_vm_insn_len_info[code[pc]]) {
        while (positions && entry + 1 < info_size && positions[entry + 1] <= pc) entry++;
        rb_event_flag_t events = body->insns_info.body[entry].events;
        if (!(events & EVENTS)) continue;

        if (probes->count == capacity) {
            capacity *= 2;
            REALLOC_N(probes->pc, unsigned int, capacity);
            REALLOC_N(probes->line, int, capacity);
            REALLOC_N(probes->events, rb_event_flag_t, capacity);
            REALLOC_N(probes->plain, VALUE, capacity);
        }
        probes->pc[probes->count] = pc;
        probes->line[probes->count] = body->insns_info.body[entry].line_no;
        probes->events[probes->count] = events;
        probes->count++;
    }
    if (!had_original) ISEQ_ORIGINAL_ISEQ_CLEAR(iseq);
    if (positions) ruby_xfree(positions);

    if (probes->count == 0) {
        free_probes(probes);
        return NULL;
    }
    return probes;
}

// Aims the hook at +iseq+, one instruction sequence of a compiled app file.
// Code outside the app never fires it.
static VALUE
tracer_target(VALUE self, VALUE iseqw, VALUE relative)
{
    (void)self;
    const rb_iseq_t *iseq = rb_iseqw_to_iseq(iseqw);
    rb_iseq_t *mutable_iseq = (rb_iseq_t *)iseq;
    struct rb_iseq_constant_body *body = (struct rb_iseq_constant_body *)ISEQ_BODY(iseq);
    rb_ractor_t *ractor = current_ractor();
    st_data_t existing;
    rb_hook_list_t *list = NULL;
    if (st_lookup(ractor->pub.targeted_hooks, (st_data_t)iseq, &existing)) {
        list = (rb_hook_list_t *)existing;
        for (hook_t *h = (hook_t *)list->hooks; h; h = h->next) {
            if (h->func == (rb_event_hook_func_t)hook) return Qfalse;
        }
    }

    probes_t *probes = find_probes(iseq);
    if (!probes) return Qfalse;

    // Every iseq in a file shares its path, and the ractor keeps the iseqs
    // themselves alive and in place.
    if (relative != last_pinned) {
        rb_gc_register_mark_object(relative);
        last_pinned = relative;
    }
    probes->relative = relative;

    VALUE *encoded = (VALUE *)body->iseq_encoded;
    for (unsigned int i = 0; i < probes->count; i++) probes->plain[i] = encoded[probes->pc[i]];

    hook_t *h = ZALLOC(hook_t);
    h->hook_flags = RUBY_EVENT_HOOK_FLAG_SAFE | RUBY_EVENT_HOOK_FLAG_RAW_ARG;
    h->events = EVENTS;
    h->func = (rb_event_hook_func_t)hook;
    // A fixnum, so the GC marking the hook list leaves the pointer alone.
    h->data = (VALUE)probes | RUBY_FIXNUM_FLAG;
    if (!list) {
        list = ZALLOC(rb_hook_list_t);
        list->type = hook_list_type_targeted_iseq;
        st_insert(ractor->pub.targeted_hooks, (st_data_t)iseq, (st_data_t)list);
    }
    h->next = (hook_t *)list->hooks;
    list->hooks = (struct rb_event_hook_struct *)h;
    list->events |= EVENTS;
    mutable_iseq->aux.exec.local_hooks_cnt++;

    // Tracing the iseq for events beyond the global ones picks up the hook
    // list's events too. Going through a TracePoint instead would throw away
    // everything YJIT has compiled, every time.
    rb_event_flag_t global = iseq->aux.exec.global_trace_events;
    rb_iseq_trace_set(iseq, global | EVENTS);
    mutable_iseq->aux.exec.global_trace_events = global;

    // Only a line probe the VM had untraced can go off and come back. One
    // that was already traced belongs to something else, like coverage.
    // Lines ahead of an entry stay armed, since YJIT can jump straight to
    // them from compiled callers.
    unsigned int entry = probes->count;
    for (unsigned int i = 0; i < probes->count; i++) {
        if (probes->events[i] & ENTRIES) {
            entry = i;
            break;
        }
    }
    for (unsigned int i = 0; i < probes->count; i++) {
        int line_only = (probes->events[i] & EVENTS) == RUBY_EVENT_LINE;
        if (!line_only || i < entry || encoded[probes->pc[i]] == probes->plain[i]) probes->plain[i] = 0;
    }

#if USE_YJIT || USE_ZJIT
    // The interpreter hands an iseq to a JIT at a call count it can no
    // longer reach, so probes that come back are always heard.
    body->jit_entry_calls = ULONG_MAX / 2;
    body->jit_exception_calls = ULONG_MAX / 2;
#endif
    return Qtrue;
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

    rearm();
    window = rb_hash_new();
    receivers = identity_hash();
    last_relative = Qnil;
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

    rearm();
    VALUE lines = rb_hash_new();
    rb_hash_foreach(window, collect_lines, lines);
    VALUE result = rb_assoc_new(lines, rb_funcall(receivers, rb_intern("keys"), 0));
    window = Qnil;
    receivers = Qnil;
    last_relative = Qnil;
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

    stacks = identity_hash();
    load_facts = rb_hash_new();
    load_called = rb_hash_new();
    owner_files = identity_hash();
    boot_lines = rb_hash_new();

    rb_gc_register_address(&stacks);
    rb_gc_register_address(&window);
    rb_gc_register_address(&receivers);
    rb_gc_register_address(&last_receiver);
    rb_gc_register_address(&load_facts);
    rb_gc_register_address(&load_called);
    rb_gc_register_address(&owner_files);
    rb_gc_register_address(&boot_lines);
    rb_gc_register_address(&last_relative);
    rb_gc_register_address(&last_map);
    rb_gc_register_address(&last_pinned);

    rb_define_const(mTracer, "SUPPORTED", Qtrue);
    rb_define_singleton_method(mTracer, "_install", tracer_install, 0);
    rb_define_singleton_method(mTracer, "installed?", tracer_installed_p, 0);
    rb_define_singleton_method(mTracer, "_target", tracer_target, 2);
    rb_define_singleton_method(mTracer, "open_window", tracer_open_window, 0);
    rb_define_singleton_method(mTracer, "_close_window", tracer_close_window, 0);
    rb_define_singleton_method(mTracer, "_drain_load_facts", tracer_drain_load_facts, 0);
    rb_define_singleton_method(mTracer, "_drain_load_called", tracer_drain_load_called, 0);
    rb_define_singleton_method(mTracer, "drain_boot_lines", tracer_drain_boot_lines, 0);
    rb_define_singleton_method(mTracer, "_owner_files", tracer_owner_files, 0);
}

#else

#include <ruby.h>

static VALUE
installed_p(VALUE self)
{
    (void)self;
    return Qfalse;
}

void
Init_riptide_native(void)
{
    VALUE mTracer = rb_define_module_under(rb_define_module("Riptide"), "Tracer");
    rb_define_const(mTracer, "SUPPORTED", Qfalse);
    rb_define_singleton_method(mTracer, "installed?", installed_p, 0);
}

#endif
