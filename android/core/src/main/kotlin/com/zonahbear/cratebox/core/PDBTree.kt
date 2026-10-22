// Editing a stick's playlist tree in memory (Devices.swift's edit helpers): the result goes to PDB.writePlaylists.
// Every function returns the new tree; ids are export.pdb's playlist ids, parent 0 = the top level.
package com.zonahbear.cratebox.core

object PDBTree {
    private fun at(tree: List<PDBPlaylist>, id: Long, f: (PDBPlaylist) -> PDBPlaylist) = tree.map { if (it.id == id) f(it) else it }
    private fun nextSort(tree: List<PDBPlaylist>, parent: Long) = (tree.filter { it.parent == parent }.maxOfOrNull { it.sort } ?: 0) + 1
    fun nextId(tree: List<PDBPlaylist>) = (tree.maxOfOrNull { it.id } ?: 0) + 1

    fun addTracks(tree: List<PDBPlaylist>, id: Long, tracks: List<Long>) = at(tree, id) { it.copy(tracks = it.tracks + tracks) }
    fun removeTracks(tree: List<PDBPlaylist>, id: Long, positions: Set<Int>) =
        at(tree, id) { p -> p.copy(tracks = p.tracks.filterIndexed { i, _ -> i !in positions }) }
    /** SwiftUI's move(fromOffsets:toOffset:) */
    fun moveTracks(tree: List<PDBPlaylist>, id: Long, from: Set<Int>, to: Int) = at(tree, id) { p ->
        val moving = p.tracks.filterIndexed { i, _ -> i in from }
        val rest = p.tracks.filterIndexed { i, _ -> i !in from }.toMutableList()
        rest.addAll((to - from.count { it < to }).coerceIn(0, rest.size), moving)
        p.copy(tracks = rest)
    }
    fun rename(tree: List<PDBPlaylist>, id: Long, name: String) = at(tree, id) { it.copy(name = name) }
    /** a node and everything under it */
    fun delete(tree: List<PDBPlaylist>, id: Long): List<PDBPlaylist> {
        val kill = mutableSetOf(id)
        var grew = true
        while (grew) { grew = false; for (x in tree) if (x.parent != 0L && x.parent in kill && x.id !in kill) { kill.add(x.id); grew = true } }
        return tree.filter { it.id !in kill }
    }
    /** null when `parent` is the node itself or inside it */
    fun moveNode(tree: List<PDBPlaylist>, id: Long, parent: Long): List<PDBPlaylist>? {
        var p = parent
        while (p != 0L) { if (p == id) return null; p = tree.firstOrNull { it.id == p }?.parent ?: 0 }
        val sort = nextSort(tree, parent)
        return at(tree, id) { it.copy(parent = parent, sort = sort) }
    }
    /** a copy of a playlist, next to it */
    fun duplicate(tree: List<PDBPlaylist>, id: Long): List<PDBPlaylist> {
        val n = tree.firstOrNull { it.id == id }?.takeIf { !it.folder } ?: return tree
        return tree + PDBPlaylist(nextId(tree), n.parent, sort = nextSort(tree, n.parent), folder = false, name = n.name + " copy", tracks = n.tracks)
    }
    fun newNode(tree: List<PDBPlaylist>, name: String, folder: Boolean, parent: Long = 0): Pair<List<PDBPlaylist>, Long> {
        val id = nextId(tree)
        return (tree + PDBPlaylist(id, parent, sort = nextSort(tree, parent), folder = folder, name = name)) to id
    }
    /** the order writePlaylists gets: by parent, then sort, then position; folders hold no tracks */
    fun forWrite(tree: List<PDBPlaylist>): List<PDBPlaylist> = tree.withIndex()
        .sortedWith(compareBy({ it.value.parent }, { it.value.sort }, { it.index }))
        .map { if (it.value.folder) it.value.copy(tracks = emptyList()) else it.value }

    /** a quick fingerprint of export.pdb (size + the header's sequence number) to tell whether rekordbox wrote it since */
    fun stamp(b: ByteArray): String =
        if (b.size >= 24) "${b.size}:${(b[20].toLong() and 0xff) or ((b[21].toLong() and 0xff) shl 8) or ((b[22].toLong() and 0xff) shl 16) or ((b[23].toLong() and 0xff) shl 24)}"
        else "${b.size}"
}
