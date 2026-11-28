/// Which XPC callers the daemon trusts: first the code (`ClientRequirement`, checked by the
/// system), then the account it runs for (`CallerPolicy`).
public enum ClientRequirement {
    /// A Developer ID signature of the app by `team` (Apple's markers for the Developer ID
    /// intermediate and leaf certificates), not any other certificate of that team.
    public static func developerID(appID: String, team: String) -> String {
        "anchor apple generic and identifier \"\(appID)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Ad-hoc builds: this exact code only.
    public static func exactBuild(appID: String, cdhash: String) -> String {
        "identifier \"\(appID)\" and cdhash H\"\(cdhash)\""
    }
}

public enum CallerPolicy {
    /// Whether a caller may change what the daemon does (reading the status needs nothing more
    /// than the signature): root, the user at the screen, or the user whose app the daemon is
    /// following (still allowed after switching to another account that does not run ClamStop).
    public static func mayControl(caller: UInt32, consoleUser: UInt32?, appUser: UInt32?) -> Bool {
        caller == 0 || caller == consoleUser || caller == appUser
    }
}
