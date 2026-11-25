import IBrain

/// Derived/rebuildable cache only. Pin source and domain records remain the
/// authority; this alias avoids the SDK module/enum name collision in clients.
public typealias PinDerivedMemoryStore = MemoryStore
