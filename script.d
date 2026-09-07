module assign_tutors;

import std.stdio : writeln, writefln, stderr, File;
import std.file : readText;
import std.string : splitLines, split, strip, toLower, indexOf, join;
import std.algorithm.iteration : map;
import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.array : array;
import std.range : iota;
import std.random : Random, unpredictableSeed, randomShuffle;

/** Staff record with a running assignment count. */
struct Staff
{
    string id;           /// staff ID
    string discipline;   /// Discipline
    size_t existing = 0; /// students already validly assigned to this staff
    size_t added = 0;    /// students assigned this run
}

/** A Programme Name keyword mapped to the staff disciplines it may draw from. */
struct Rule
{
    string keyword;   /// case-insensitive substring of Programme Name
    string[] pool;    /// eligible staff disciplines (empty pool is never stored here)
}

/** Least-loaded in-pool and least-loaded overall staff indices from a search. */
struct Pick
{
    size_t inPool = size_t.max; /// least-loaded staff whose discipline is in pool
    size_t any = size_t.max;    /// least-loaded staff regardless of discipline
}

/** Least-loaded in-pool and overall staff whose load is below threshold. */
Pick pickUnder(const Staff[] staff, const size_t[] order, const(string)[] pool, double threshold) @safe
{
    Pick p;
    foreach (k; order)
    {
        if (staff[k].total >= threshold)
            continue;
        if (p.any == size_t.max || staff[k].total < staff[p.any].total)
            p.any = k;
        if ((pool.length == 0 || pool.canFind(staff[k].discipline))
            && (p.inPool == size_t.max || staff[k].total < staff[p.inPool].total))
            p.inPool = k;
    }
    return p;
}

/** Current assigned load for a staff member. */
size_t total(const Staff s) pure nothrow @safe @nogc
{
    return s.existing + s.added;
}

/** Split one TSV line into fields, preserving empty trailing cells. */
string[] fields(string line) pure @safe
{
    return line.split("\t");
}

/** Eligible staff disciplines for a programme, or null to mean any staff. */
const(string)[] poolFor(string programme, const Rule[] rules) @safe
{
    const p = programme.toLower;
    foreach (ref r; rules)
        if (p.indexOf(r.keyword) >= 0)
            return r.pool;
    return null;
}

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("Usage:\nassign_tutors student_data.tsv staff_data.tsv");
        return 1;
    }

    // --- staff ---
    Staff[] staff;
    bool[string] validId;
    size_t[string] idxOf;
    {
        auto lines = readText(args[2]).splitLines;
        auto head = lines[0].fields;
        const idCol = head.countCol("ID");
        const discCol = head.countCol("Discipline");
        foreach (line; lines[1 .. $])
        {
            if (line.strip.length == 0)
                continue;
            auto f = line.fields;
            auto s = Staff(f[idCol].strip, f[discCol].strip);
            idxOf[s.id] = staff.length;
            validId[s.id] = true;
            staff ~= s;
        }
    }

    // --- students (kept verbatim for re-output) ---
    auto slines = readText(args[1]).splitLines;
    auto shead = slines[0].fields;
    const ptCol = shead.countCol("PT");
    const progCol = shead.countCol("Programme Name");
    auto rows = slines[1 .. $].map!(l => l.fields).array;

    // existing load = students whose PT is a real staff ID (kept as-is)
    foreach (ref row; rows)
    {
        const pt = row[ptCol].strip;
        if (pt in validId)
            staff[idxOf[pt]].existing++;
    }

    // programme-name -> discipline pool rules (first substring match wins)
    auto geo = ["Physical Geography and Environmental Science",
                "Cold and Palaeo Environments"];
    const Rule[] rules = [
        Rule("forensic",                 ["Forensics"]),
        Rule("nutrition",                ["Food Science & Nutrition"]),
        Rule("food science",             ["Food Science & Nutrition"]),
        Rule("bio",                      ["Biomedical Sciences"]),
        Rule("medical",                  ["Biomedical Sciences"]),
        Rule("medsci",                   ["Biomedical Sciences"]),
        Rule("chemistry",                ["Chemistry"]),
        Rule("chemical",                 ["Chemistry"]),
        Rule("nebosh",                   geo),
        Rule("occupational",             geo),
        Rule("physical geography",       geo),
        Rule("environmental",            geo),
        Rule("arts (honours) geography", ["Human Geography"]),
        Rule("disaster",                 ["Human Geography"]),
        Rule("development",              ["Human Geography"]),
        Rule("geography",                geo),
    ];

    auto rng = Random(unpredictableSeed);
    auto staffOrder = iota(staff.length).array;
    auto newCol = new string[](rows.length); // assigned staff ID, "" when kept
    size_t needing, spilled;

    // keep every tutor within mean +/- 5 of the team mean
    const meanLoad = cast(double) rows.length / staff.length;
    const floorCap = meanLoad - 5.0;
    const ceilCap = meanLoad + 5.0;

    // assign anyone Unallocated/blank or holding a stale (non-staff) PT
    foreach (i, ref row; rows)
    {
        const pt = row[ptCol].strip;
        if (pt in validId)
            continue;
        needing++;
        auto pool = poolFor(row[progCol], rules);
        staffOrder.randomShuffle(rng); // random tie-break among equal-load staff

        // fill everyone up to the floor first, then toward the ceiling; prefer the team throughout
        size_t best;
        auto below = pickUnder(staff, staffOrder, pool, floorCap);
        if (below.any != size_t.max)
            best = below.inPool != size_t.max ? below.inPool : below.any;
        else
        {
            auto under = pickUnder(staff, staffOrder, pool, ceilCap);
            if (under.any != size_t.max)
                best = under.inPool != size_t.max ? under.inPool : under.any;
            else
            {
                best = staffOrder[0]; // everyone at ceiling: fall back to least loaded overall
                foreach (k; staffOrder)
                    if (staff[k].total < staff[best].total)
                        best = k;
            }
        }
        if (pool.length && !pool.canFind(staff[best].discipline))
            spilled++; // team was full within the band, assigned outside to keep balance
        staff[best].added++;
        newCol[i] = staff[best].id;
    }

    // --- output: original columns + one new column ---
    auto outFields = shead ~ "New tutor ID";
    writeln(outFields.join("\t"));
    foreach (i, ref row; rows)
        writeln((row ~ newCol[i]).join("\t"));

    // --- diagnostics to stderr ---
    stderr.writefln("Students: %d", rows.length);
    stderr.writefln("Kept (valid PT): %d", rows.length - needing);
    stderr.writefln("Reassigned: %d (of which spilled outside their team to keep balance: %d)",
                    needing, spilled);
    stderr.writefln("Target band: mean %.1f, floor %.1f, ceiling %.1f", meanLoad, floorCap, ceilCap);
    stderr.writeln("Load per staff after assignment (existing + new = total):");
    staffOrder.sort!((a, b) => staff[a].existing + staff[a].added
                             > staff[b].existing + staff[b].added);
    stderr.writeln("discipline\tid\texisting\tnew\ttotal");
    foreach (k; staffOrder)
        stderr.writefln("%s\t%s\t%d\t%d\t%d", staff[k].discipline, staff[k].id,
                        staff[k].existing, staff[k].added, staff[k].existing + staff[k].added);

    return 0;
}

/** Header column index for a name, or assert if the column is absent. */
size_t countCol(const string[] header, string name) @safe
{
    const i = header.countUntilName(name);
    assert(i >= 0, "missing column: " ~ name);
    return cast(size_t) i;
}

/** Index of the first header cell equal to name, or -1. */
ptrdiff_t countUntilName(const string[] header, string name) pure @safe nothrow
{
    foreach (i, h; header)
        if (h.strip == name)
            return i;
    return -1;
}

