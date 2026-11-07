#!/usr/bin/env python3
# SPDX-FileCopyrightText: Lambda993
# SPDX-License-Identifier: GPL-3.0-only
"""Writes fast-tech/lua/unit_table.lua from data/units.json.

Run it from the repo's top folder after every change to the table. A brain
reads Lua modules, so the fields it uses are copied into one.
"""
import json


def words(values):
    return "{" + ",".join(json.dumps(v) for v in values) + "}"


rows = json.load(open("data/units.json", encoding="utf-8"))
with open("fast-tech/lua/unit_table.lua", "w", encoding="utf-8", newline="\n") as out:
    out.write("-- SPDX-FileCopyrightText: Lambda993\n")
    out.write("-- SPDX-License-Identifier: GPL-3.0-only\n\n")
    out.write("-- Generated from data/units.json by data/make_unit_table.py: do not edit.\n")
    out.write("-- threat, priority targets, ignored units, attack-only targets, tags.\n")
    out.write("return {\n")
    for row in rows:
        out.write('["%s"]={%d,%s,%s,%s,%s},\n' % (
            row["id"].upper(), row["threat_level"], words(row["priority_targets"]),
            words(row["ignore_units"]), words(row["attack_only"]), words(row["tags"])))
    out.write("}\n")
