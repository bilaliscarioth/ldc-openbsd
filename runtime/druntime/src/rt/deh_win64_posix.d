/**
 * Implementation of exception handling support routines for Win64.
 *
 * Note that this code also support POSIX, however since v2.070.0,
 * DWARF exception handling is used instead when possible,
 * as it provides better compatibility with C++.
 *
 * Copyright: Copyright Digital Mars 2000 - 2013.
 * License: Distributed under the
 *      $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0).
 *    (See accompanying file LICENSE)
 * Authors:   Walter Bright, Sean Kelly
 * Source: $(DRUNTIMESRC rt/deh_win64_posix.d)
 * See_Also: https://docs.microsoft.com/en-us/cpp/build/exception-handling-x64?view=vs-2019
 */

module rt.deh_win64_posix;

version (LDC)
{
    // LDC only needs _d_eh_swapContext
    version (CRuntime_Microsoft)
    {
        // _d_eh_swapContext implemented in ldc.eh_msvc
    }
    else
        version = Win64_Posix;
}
else
{
	version (Win64)
	    version = Win64_Posix;
	version (Posix)
	    version = Win64_Posix;
}

version (Win64_Posix):

version (OSX)
    version = Darwin;
else version (iOS)
    version = Darwin;
else version (TVOS)
    version = Darwin;
else version (WatchOS)
    version = Darwin;

version (LDC) {} else
{

//debug=PRINTF;
debug(PRINTF) import core.stdc.stdio : printf;

extern (C)
{
    int _d_isbaseof(ClassInfo oc, ClassInfo c);
    void _d_createTrace(Throwable o, void* context);
}

alias int function() fp_t;   // function pointer in ambient memory model

// DHandlerInfo table is generated by except_gentables() in eh.c

struct DHandlerInfo
{
    uint offset;                // offset from function address to start of guarded section
    uint endoffset;             // offset of end of guarded section
    int prev_index;             // previous table index
    uint cioffset;              // offset to DCatchInfo data from start of table (!=0 if try-catch)
    size_t finally_offset;      // offset to finally code to execute
                                // (!=0 if try-finally)
}

// Address of DHandlerTable, searched for by eh_finddata()

struct DHandlerTable
{
    uint espoffset;             // offset of ESP from EBP
    uint retoffset;             // offset from start of function to return code
    size_t nhandlers;           // dimension of handler_info[] (use size_t to set alignment of handler_info[])
    DHandlerInfo[1] handler_info;
}

struct DCatchBlock
{
    ClassInfo type;             // catch type
    size_t bpoffset;            // EBP offset of catch var
    size_t codeoffset;          // catch handler offset
}

// Create one of these for each try-catch
struct DCatchInfo
{
    size_t ncatches;                    // number of catch blocks
    DCatchBlock[1] catch_block;         // data for each catch block
}

// One of these is generated for each function with try-catch or try-finally

struct FuncTable
{
    void *fptr;                 // pointer to start of function
    DHandlerTable *handlertable; // eh data for this function
    uint fsize;         // size of function in bytes
}

} // !LDC

private
{
    struct InFlight
    {
        InFlight*   next;
        void*       addr;
        Throwable   t;
    }

    InFlight* __inflight = null;

    /// __inflight is per-stack, not per-thread, and as such needs to be
    /// swapped out on fiber context switches.
    extern(C) void* _d_eh_swapContext(void* newContext) nothrow @nogc
    {
        auto old = __inflight;
        __inflight = cast(InFlight*)newContext;
        return old;
    }
}

version (LDC) {} else:

void terminate()
{
    asm
    {
        hlt ;
    }
}

/*******************************************
 * Given address that is inside a function,
 * figure out which function it is in.
 * Return DHandlerTable if there is one, NULL if not.
 */

immutable(FuncTable)* __eh_finddata(void *address)
{
    import rt.sections;
    foreach (ref sg; SectionGroup)
    {
        auto pstart = sg.ehTables.ptr;
        auto pend = pstart + sg.ehTables.length;
        if (auto ft = __eh_finddata(address, pstart, pend))
            return ft;
    }
    return null;
}

immutable(FuncTable)* __eh_finddata(void *address, immutable(FuncTable)* pstart, immutable(FuncTable)* pend)
{
    debug(PRINTF) printf("FuncTable.sizeof = %#zx\n", FuncTable.sizeof);
    debug(PRINTF) printf("__eh_finddata(address = %p)\n", address);
    debug(PRINTF) printf("_deh_beg = %p, _deh_end = %p\n", pstart, pend);

    for (auto ft = pstart; 1; ft++)
    {
     Lagain:
        if (ft >= pend)
            break;

        version (Win64)
        {
            /* The MS Linker has an inexplicable and erratic tendency to insert
             * 8 zero bytes between sections generated from different .obj
             * files. This kludge tries to skip over them.
             */
            if (ft.fptr == null)
            {
                ft = cast(immutable(FuncTable)*)(cast(void**)ft + 1);
                goto Lagain;
            }
        }

        debug(PRINTF) printf("  ft = %p, fptr = %p, handlertable = %p, fsize = x%03x\n",
              ft, ft.fptr, ft.handlertable, ft.fsize);

        immutable(void)* fptr = ft.fptr;
        version (Win64)
        {
            /* If linked with /DEBUG, the linker rewrites it so the function pointer points
             * to a JMP to the actual code. The address will be in the actual code, so we
             * need to follow the JMP.
             */
            if ((cast(ubyte*)fptr)[0] == 0xE9)
            {   // JMP target = RIP of next instruction + signed 32 bit displacement
                fptr = fptr + 5 + *cast(int*)(fptr + 1);
            }
        }

        if (fptr <= address &&
            address < cast(void *)(cast(char *)fptr + ft.fsize))
        {
            debug(PRINTF) printf("\tfound handler table\n");
            return ft;
        }
    }
    debug(PRINTF) printf("\tnot found\n");
    return null;
}


/******************************
 * Given EBP, find return address to caller, and caller's EBP.
 * Input:
 *   regbp       Value of EBP for current function
 *   *pretaddr   Return address
 * Output:
 *   *pretaddr   return address to caller
 * Returns:
 *   caller's EBP
 */

size_t __eh_find_caller(size_t regbp, size_t *pretaddr)
{
    size_t bp = *cast(size_t *)regbp;

    if (bp)         // if not end of call chain
    {
        // Perform sanity checks on new EBP.
        // If it is screwed up, terminate() hopefully before we do more damage.
        if (bp <= regbp)
            // stack should grow to smaller values
            terminate();

        *pretaddr = *cast(size_t *)(regbp + size_t.sizeof);
    }
    return bp;
}


/***********************************
 * Throw a D object.
 */

extern (C) void _d_throwc(Throwable h)
{
    size_t regebp;

    debug(PRINTF)
    {
        printf("_d_throw(h = %p, &h = %p)\n", h, &h);
        printf("\tvptr = %p\n", *cast(void **)h);
    }

    version (D_InlineAsm_X86)
        asm
        {
            mov regebp,EBP  ;
        }
    else version (D_InlineAsm_X86_64)
        asm
        {
            mov regebp,RBP  ;
        }
    else
        static assert(0);

    /* Increment reference count if `h` is a refcounted Throwable
     */
    auto refcount = h.refcount();
    if (refcount)       // non-zero means it's refcounted
        h.refcount() = refcount + 1;

    _d_createTrace(h, null);

//static uint abc;
//if (++abc == 2) *(char *)0=0;

//int count = 0;
    while (1)           // for each function on the stack
    {
        size_t retaddr;

        regebp = __eh_find_caller(regebp,&retaddr);
        if (!regebp)
        {   // if end of call chain
            debug(PRINTF) printf("end of call chain\n");
            break;
        }

        debug(PRINTF) printf("found caller, EBP = %#zx, retaddr = %#zx\n", regebp, retaddr);
//if (++count == 12) *(char*)0=0;
        auto func_table = __eh_finddata(cast(void *)retaddr);   // find static data associated with function
        auto handler_table = func_table ? func_table.handlertable : null;
        if (!handler_table)         // if no static data
        {
            debug(PRINTF) printf("no handler table\n");
            continue;
        }
        auto funcoffset = cast(size_t)func_table.fptr;
        version (Win64)
        {
            /* If linked with /DEBUG, the linker rewrites it so the function pointer points
             * to a JMP to the actual code. The address will be in the actual code, so we
             * need to follow the JMP.
             */
            if ((cast(ubyte*)funcoffset)[0] == 0xE9)
            {   // JMP target = RIP of next instruction + signed 32 bit displacement
                funcoffset = funcoffset + 5 + *cast(int*)(funcoffset + 1);
            }
        }
        auto spoff = handler_table.espoffset;
        auto retoffset = handler_table.retoffset;

        debug(PRINTF)
        {
            printf("retaddr = %#zx\n", retaddr);
            printf("regebp=%#zx, funcoffset=%#zx, spoff=x%x, retoffset=x%x\n",
            regebp,funcoffset,spoff,retoffset);
        }

        // Find start index for retaddr in static data
        auto dim = handler_table.nhandlers;

        debug(PRINTF)
        {
            printf("handler_info[%zd]:\n", dim);
            for (uint i = 0; i < dim; i++)
            {
                auto phi = &handler_table.handler_info.ptr[i];
                printf("\t[%d]: offset = x%04x, endoffset = x%04x, prev_index = %d, cioffset = x%04x, finally_offset = %zx\n",
                        i, phi.offset, phi.endoffset, phi.prev_index, phi.cioffset, phi.finally_offset);
            }
        }

        auto index = -1;
        for (uint i = 0; i < dim; i++)
        {
            auto phi = &handler_table.handler_info.ptr[i];

            debug(PRINTF) printf("i = %d, phi.offset = %04zx\n", i, funcoffset + phi.offset);
            if (retaddr > funcoffset + phi.offset &&
                retaddr <= funcoffset + phi.endoffset)
                index = i;
        }
        debug(PRINTF) printf("index = %d\n", index);

        if (dim)
        {
            auto phi = &handler_table.handler_info.ptr[index+1];
            debug(PRINTF) printf("next finally_offset %#zx\n", phi.finally_offset);
            auto prev = cast(InFlight*) &__inflight;
            auto curr = prev.next;

            if (curr !is null && curr.addr == cast(void*)(funcoffset + phi.finally_offset))
            {
                auto e = cast(Error)(cast(Throwable) h);
                if (e !is null && (cast(Error) curr.t) is null)
                {
                    debug(PRINTF) printf("new error %p bypassing inflight %p\n", h, curr.t);

                    e.bypassedException = curr.t;
                    prev.next = curr.next;
                    //h = cast(Object*) t;
                }
                else
                {
                    debug(PRINTF) printf("replacing thrown %p with inflight %p\n", h, __inflight.t);

                    h = Throwable.chainTogether(curr.t, cast(Throwable) h);
                    prev.next = curr.next;
                }
            }
        }

        // walk through handler table, checking each handler
        // with an index smaller than the current table_index
        int prev_ndx;
        for (auto ndx = index; ndx != -1; ndx = prev_ndx)
        {
            auto phi = &handler_table.handler_info.ptr[ndx];
            prev_ndx = phi.prev_index;
            if (phi.cioffset)
            {
                // this is a catch handler (no finally)

                auto pci = cast(DCatchInfo *)(cast(char *)handler_table + phi.cioffset);
                auto ncatches = pci.ncatches;
                for (uint i = 0; i < ncatches; i++)
                {
                    auto ci = **cast(ClassInfo **)h;

                    auto pcb = &pci.catch_block.ptr[i];

                    if (_d_isbaseof(ci, pcb.type))
                    {
                        // Matched the catch type, so we've found the handler.

                        // Initialize catch variable
                        *cast(void **)(regebp + (pcb.bpoffset)) = cast(void*)h;

                        // Jump to catch block. Does not return.
                        {
                            size_t catch_esp;
                            fp_t catch_addr;

                            catch_addr = cast(fp_t)(funcoffset + pcb.codeoffset);
                            catch_esp = regebp - handler_table.espoffset - fp_t.sizeof;
                            version (D_InlineAsm_X86)
                                asm
                                {
                                    mov     EAX,catch_esp   ;
                                    mov     ECX,catch_addr  ;
                                    mov     [EAX],ECX       ;
                                    mov     EBP,regebp      ;
                                    mov     ESP,EAX         ; // reset stack
                                    ret                     ; // jump to catch block
                                }
                            else version (D_InlineAsm_X86_64)
                                asm
                                {
                                    mov     RAX,catch_esp   ;
                                    mov     RCX,catch_esp   ;
                                    mov     RCX,catch_addr  ;
                                    mov     [RAX],RCX       ;
                                    mov     RBP,regebp      ;
                                    mov     RSP,RAX         ; // reset stack
                                    ret                     ; // jump to catch block
                                }
                            else
                                static assert(0);
                        }
                    }
                }
            }
            else if (phi.finally_offset)
            {
                // Call finally block
                // Note that it is unnecessary to adjust the ESP, as the finally block
                // accesses all items on the stack as relative to EBP.
                debug(PRINTF) printf("calling finally_offset %#zx\n", phi.finally_offset);

                auto     blockaddr = cast(void*)(funcoffset + phi.finally_offset);
                InFlight inflight;

                inflight.addr = blockaddr;
                inflight.next = __inflight;
                inflight.t    = cast(Throwable) h;
                __inflight    = &inflight;

                version (Darwin)
                {
                    version (D_InlineAsm_X86)
                        asm
                        {
                            sub     ESP,4           ;
                            push    EBX             ;
                            mov     EBX,blockaddr   ;
                            push    EBP             ;
                            mov     EBP,regebp      ;
                            call    EBX             ;
                            pop     EBP             ;
                            pop     EBX             ;
                            add     ESP,4           ;
                        }
                    else version (D_InlineAsm_X86_64)
                        asm
                        {
                            sub     RSP,8           ;
                            push    RBX             ;
                            mov     RBX,blockaddr   ;
                            push    RBP             ;
                            mov     RBP,regebp      ;
                            call    RBX             ;
                            pop     RBP             ;
                            pop     RBX             ;
                            add     RSP,8           ;
                        }
                    else
                        static assert(0);
                }
                else
                {
                    version (D_InlineAsm_X86)
                        asm
                        {
                            push    EBX             ;
                            mov     EBX,blockaddr   ;
                            push    EBP             ;
                            mov     EBP,regebp      ;
                            call    EBX             ;
                            pop     EBP             ;
                            pop     EBX             ;
                        }
                    else version (D_InlineAsm_X86_64)
                        asm
                        {
                            sub     RSP,8           ;
                            push    RBX             ;
                            mov     RBX,blockaddr   ;
                            push    RBP             ;
                            mov     RBP,regebp      ;
                            call    RBX             ;
                            pop     RBP             ;
                            pop     RBX             ;
                            add     RSP,8           ;
                        }
                    else
                        static assert(0);
                }

                if (__inflight is &inflight)
                    __inflight = __inflight.next;
            }
        }
    }
    terminate();
}
