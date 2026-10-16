// Names from VEConfig.exe's variable-ID name table (pointer table at VA 0x567048).
// Delphi enum order: 0 NoVariableID, 1...38 RAM variables, 39...118 flag bits, 119...310 settings.
// A leading "@" marks items VE Configure treats as hidden or obsolete. See docs/re/02-settings.md.

public enum SettingNames {
    public static let ram: [String] = [
        "UMainsRMS", "IMainsRMS", "UInvRMS", "IInvRMS", "UBat", "IBat_dA", "RippleUBatInRMS",
        "PeriodTime", "MainsPeriodTime", "RelativeSignedILoad", "@_VirtualSwitchPosition",
        "@_IgnoreACInput", "@pMultifunctionalRelay", "ChargePercentage", "PInverterSlow",
        "PMainsSlow", "POutSlow", "PInverterFast", "PMainsFast", "POutFast", "UBatIn", "TBat",
        "UBatTCFiltered", "cmdRAMFlags", "L2_RelativeSignedIOut", "L2_UOut", "Spare26", "Spare27",
        "Spare28", "Spare29", "Spare30", "Spare31", "L2_UMainsRMS", "L2_ReverseSignedIMainsRMS",
        "L2_PMains", "L2_PMainsSlow", "L2_POut", "L2_POutSlow",
    ]

    public static let flags: [String] = [
        "@_ObsoleteThreePhaseSystem", "@_ObsoleteThreePhaseLeader", "_60Hz",
        "_DisableMainsWaveShapeCheck", "_NoBulkProtection", "_AssistEnabled", "_DisableCharge",
        "_DisableBFLockOnLargeCurrents", "_DisableAES", "_DisableLowRippleCheck",
        "_DisableHighRippleCheck", "_EnableReducedFloat", "@_ObsoleteCBulkContainsCharge",
        "_DisableGndRelay", "_UseConstantTwinPWMDuringCharge", "_RemoteOverrulesAC1",
        "@_vsonBulkProtection", "@_vsonTemperaturePreAlarm", "@_vsonLowBatteryPreAlarm",
        "@_vsonOverloadPreAlarm", "@_vsonUBatRipplePreAlarm", "@_vsoffTemperaturePreAlarm",
        "@_vsoffLowBatteryPreAlarm", "@_vsoffOverloadPreAlarm", "@_vsoffUBatRipplePreAlarm",
        "@_vsonWhenGeneralFailure", "@_vsInvert", "_AcceptWideInputFrequency",
        "_TakeGeneratorDelayIntoAccount", "_EnableTPTBMode", "_RemoteOverrulesAC0", "_UseLPSInAES",
        "@_vs2offWhenAC1Available", "@_vs2Invert", "@_vsSetInverterPeriodTimeWhenVS",
        "@_vsSetInverterPeriodTimeOnUBat", "_LithiumBattery", "_AllowEnableFeedIn",
        "_AllowIMainsHigherThanMaxRelayCurrent", "_ConfiguredForVEBusBMS", "@_DisableVSense",
        "_PreferRenewableEnergy",
    ] + (42..<64).map { "@EBIT_Spare\($0)" } + ["@_ShortCircuitIsFatal"] + (1..<16).map { "@pEBIT_Spare\($0)" }

    /// Flag bit `n` lives in setting `flagWords[n / 16]`, bit `n % 16`.
    public static let flagWords = [0, 1, 60, 61, 82]

    public static let settings: [String] = [
        "eestFlags#0", "eestFlags#2", "eestUBatAbsorption", "eestUBatFloat", "eestIBatBulk",
        "eestRequestedInvVoltage", "eestIMainsLimit", "eestEqualiseQuarters", "eestFloatDays",
        "eestMaxAbsorptionHours", "eestChargeCharacteristic", "eestUBat2LowInvert",
        "eestUBatLowMargin", "@eestObsoleteNrOfSlaves", "@eestObsoleteThreePhase", "@eevsUsage",
        "@eevsonILoadHigh", "@eevsonUBatHigh", "@eevsonUBatLow", "@eevstonILoadHigh",
        "@eevstonUBatHigh", "@eevstonUBatLow", "@eevstonNotCharging", "@eevstonFanOn",
        "@eevstonTemperatureAlarm", "@eevstonLowBatteryAlarm", "@eevstonOverloadAlarm",
        "@eevstonUBatRippleAlarm", "@eevsoffILoadLow", "@eevsoffUBatHigh", "@eevsoffUBatLow",
        "@eevstoffILoadLow", "@eevstoffUBatHigh", "@eevstoffUBatLow", "@eevstoffCharging",
        "@eevstoffFanOff", "@eevstoffChargeBulkFinished", "@eevstoffNoVSOnCondition",
        "@eevstoffNoACInput", "@eevstoffTemperatureAlarm", "@eevstoffLowBatteryAlarm",
        "@eevstoffOverloadAlarm", "@eevstoffUBatRippleAlarm", "@eevsMinimumOnTime",
        "eestUMains2LowForFine", "eestUMains2LowForFineHysterese", "eestUMains2High",
        "eestUMains2HighHysterese", "eestAssBoostFactor", "eestIMainsLimitAC1", "eestIInv2AES",
        "eestIInvAESHyst", "@eevs2onILoadHigh", "@eevs2tonILoadHigh", "@eevs2onUBatLow",
        "@eevs2tonUBatLow", "@eevs2offILoadLow", "@eevs2toffILoadLow", "@eevs2offUBat",
        "@eevs2toffUBat", "eestFlags#4", "eestFlags#6", "eestvllInverterPeriodTime",
        "eestUBatPreAlarmOffset", "eestBatteryCapacity", "eestChargePercentageResetValue",
        "@eefsUBatStart", "@eefstUBatStart", "@eefsUBatStop", "@eefstUBatStop", "@eevs2onSOC",
        "eestvllTempCompensation", "eestChargeEfficiency", "eestIInvLimitDuringAssist",
        "eestAbsToFloatSOCResetValue", "eestIBatForStopAbsorption_dA", "@eestInvertRedundancy",
        "@eestExpectedPresenceFlags#0", "@eestExpectedPresenceFlags#2", "@eestRelativePhaseInfo",
        "@eestMyShortID", "eecvGridCode", "eecvstPermanentFlags#0", "eestSOCStopInvert",
        "eestSOCStartInvert", "@InfoID0", "eestTBatStopCharge", "eestTempCompensationSlope#0",
        "eestUBatDontCharge#0", "eestCurrentSensorRating",
    ] + (0...37).reversed().map { "@NotDefinedYet\($0)" }
      + ["@GridSettingsValidCheckerA"] + (0..<61).map { "GridSettingsInt\($0)" }
      + ["GeneralGridSettingsInt", "@GridSettingsValidCheckerB"]

    public static let gridCodes: [String] = [
        "None", "NotCompatible", "UK", "CEI", "VDEZiehl", "VDENew", "AS4777", "NZS4777", "NRS097",
        "France", "Spain", "Belgium", "Austria", "Chile", "Romania", "NZS4777_NByp", "AS4777_NByp",
        "Europe", "Denmark1", "Denmark2", "N_Ireland", "NotCompatible_NByp", "AS4777MA",
        "AS4777MB", "AS4777MC", "NZS4777M", "AS4777MA_NByp", "AS4777MB_NByp", "AS4777MC_NByp",
        "NZS4777M_NByp", "Czech", "UK98IsUKLimitedTo16A", "Poland",
    ]

    public static func setting(named name: String) -> Int? {
        settings.firstIndex(of: name) ?? settings.firstIndex(of: "@" + name)
    }

    public static func flag(named name: String) -> Int? {
        flags.firstIndex(of: name) ?? flags.firstIndex(of: "@" + name)
    }
}
