import React from "react";
import { View, Text, Switch, StyleSheet, ScrollView } from "react-native";
import { Colors, FontFamily, FontSize, Space, Radius } from "../lib/theme";
import { useSettingsContext } from "../context/SettingsContext";

export default function SettingsScreen() {
  const { settings, updateSettings } = useSettingsContext();

  return (
    <ScrollView style={styles.container}>
      <View style={styles.card}>
        <Text style={styles.sectionHeader}>Pairing</Text>

        <View style={styles.row}>
          <View style={styles.rowText}>
            <Text style={styles.rowLabel}>Show pairing confidence</Text>
          </View>
          <Switch
            value={settings.showPairingConfidence}
            onValueChange={(val) =>
              updateSettings({ showPairingConfidence: val })
            }
            trackColor={{ false: Colors.border, true: Colors.cyan }}
            thumbColor="#fff"
          />
        </View>

        <Text style={styles.sectionFooter}>
          Show advanced data-quality details on swimmer pairing cards.
        </Text>
      </View>

      <View style={styles.footer}>
        <Text style={styles.version}>Hydrolyze v1.0</Text>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: Colors.base,
  },
  card: {
    backgroundColor: Colors.surface,
    borderRadius: Radius.lg,
    marginHorizontal: Space[4],
    marginTop: Space[6],
    overflow: "hidden",
  },
  sectionHeader: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 13,
    color: Colors.muted,
    textTransform: "uppercase",
    letterSpacing: 0.5,
    paddingHorizontal: Space[4],
    paddingTop: Space[4],
    paddingBottom: Space[2],
  },
  row: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: Space[4],
    paddingVertical: Space[3],
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: Colors.border,
  },
  rowText: { flex: 1, paddingRight: Space[3] },
  rowLabel: {
    fontFamily: FontFamily.uiMedium,
    fontSize: 17,
    color: Colors.text,
  },
  sectionFooter: {
    fontFamily: FontFamily.ui,
    fontSize: 13,
    color: Colors.muted,
    paddingHorizontal: Space[4],
    paddingTop: Space[2],
    paddingBottom: Space[4],
    lineHeight: 18,
  },
  footer: { padding: Space[6], marginTop: Space[4] },
  version: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.dim,
    textAlign: "center",
  },
});
