/**
 * Swimmers tab — roster management with group sections.
 * Route: /(tabs)/swimmers
 */

import { useState, useCallback } from "react";
import {
  View,
  Text,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  Alert,
  TextInput,
  Pressable,
} from "react-native";
import { useRouter, useFocusEffect } from "expo-router";
import { useAuth } from "../../context/AuthContext";
import {
  getSwimmers,
  getGroups,
  createGroup,
  deleteGroup,
  deleteSwimmer,
  getInitials,
  type Swimmer,
  type Group,
} from "../../lib/swimmers";
import {
  Colors,
  FontFamily,
  FontSize,
  Space,
  Radius,
  TouchTarget,
} from "../../lib/theme";

interface GroupWithSwimmers extends Group {
  swimmerIds: string[];
}

export default function SwimmersScreen() {
  const { coachId } = useAuth();
  const router = useRouter();
  const [groups, setGroups] = useState<GroupWithSwimmers[]>([]);
  const [swimmers, setSwimmers] = useState<Swimmer[]>([]);
  const [loading, setLoading] = useState(true);
  const [showAddGroup, setShowAddGroup] = useState(false);

  useFocusEffect(
    useCallback(() => {
      loadData();
    }, [coachId]),
  );

  async function loadData() {
    if (!coachId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    const [swimmerList, groupList] = await Promise.all([
      getSwimmers(coachId),
      getGroups(coachId),
    ]);

    const groupsWithSwimmers: GroupWithSwimmers[] = groupList.map((g) => ({
      ...g,
      swimmerIds: swimmerList
        .filter((s) => s.groups.some((sg) => sg.id === g.id))
        .map((s) => s.id),
    }));

    setGroups(groupsWithSwimmers);
    setSwimmers(swimmerList);
    setLoading(false);
  }

  async function handleCreateGroup(name: string) {
    if (!name.trim() || !coachId) return;
    try {
      await createGroup(coachId, name.trim());
      setShowAddGroup(false);
      loadData();
    } catch (e) {
      Alert.alert("Error", "Could not create group");
    }
  }

  async function handleDeleteGroup(group: GroupWithSwimmers) {
    Alert.alert(
      `Delete "${group.name}"?`,
      `${group.swimmerIds.length} swimmer(s) will become ungrouped.`,
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Delete",
          style: "destructive",
          onPress: async () => {
            try {
              await deleteGroup(group.id);
              loadData();
            } catch (e) {
              Alert.alert("Error", "Could not delete group");
            }
          },
        },
      ],
    );
  }

  async function handleDeleteSwimmer(swimmer: Swimmer) {
    Alert.alert(
      `Delete ${swimmer.first_name}?`,
      "Their times and PBs will be preserved.",
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Delete",
          style: "destructive",
          onPress: async () => {
            try {
              await deleteSwimmer(swimmer.id);
              loadData();
            } catch (e) {
              Alert.alert("Error", "Could not delete swimmer");
            }
          },
        },
      ],
    );
  }

  function swimmersInGroup(groupId: string): Swimmer[] {
    return swimmers.filter((s) => s.groups.some((g) => g.id === groupId));
  }

  function ungrouped(): Swimmer[] {
    return swimmers.filter((s) => s.groups.length === 0);
  }

  function displayName(s: Swimmer): string {
    return s.last_name ? `${s.first_name} ${s.last_name}` : s.first_name;
  }

  function renderSwimmerRow(s: Swimmer) {
    const initials = getInitials(s.first_name, s.last_name);
    return (
      <TouchableOpacity
        key={s.id}
        style={styles.swimmerRow}
        onPress={() => router.push(`/swimmers/${s.id}`)}
        onLongPress={() => handleDeleteSwimmer(s)}
        activeOpacity={0.7}
      >
        <View style={styles.initialsCircle}>
          <Text style={styles.initialsText}>{initials}</Text>
        </View>
        <Text style={styles.swimmerName}>{displayName(s)}</Text>
        <Text style={styles.chevron}>›</Text>
      </TouchableOpacity>
    );
  }

  return (
    <View style={styles.container}>
      {/* Header */}
      <View style={styles.header}>
        <Text style={styles.screenLabel}>SWIMMERS</Text>
        <View style={styles.headerActions}>
          <TouchableOpacity
            style={styles.headerBtn}
            onPress={() => router.push("/swimmer-sheet")}
          >
            <Text style={styles.headerBtnText}>+ Add</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={styles.headerBtn}
            onPress={() => setShowAddGroup(true)}
          >
            <Text style={styles.headerBtnText}>+ Group</Text>
          </TouchableOpacity>
        </View>
      </View>

      {/* Add group inline */}
      {showAddGroup && (
        <AddGroupInline
          onSubmit={handleCreateGroup}
          onCancel={() => setShowAddGroup(false)}
        />
      )}

      {/* List */}
      <ScrollView
        style={styles.list}
        contentContainerStyle={styles.listContent}
      >
        {groups.map((group) => (
          <View key={group.id} style={styles.groupSection}>
            <Pressable
              onLongPress={() => handleDeleteGroup(group)}
              delayLongPress={500}
            >
              <View style={styles.groupHeader}>
                <Text style={styles.groupName}>{group.name}</Text>
                <Text style={styles.groupCount}>{group.swimmerIds.length}</Text>
              </View>
            </Pressable>
            <View style={styles.groupList}>
              {swimmersInGroup(group.id).length === 0 ? (
                <Text style={styles.groupEmpty}>No swimmers</Text>
              ) : (
                swimmersInGroup(group.id).map(renderSwimmerRow)
              )}
            </View>
          </View>
        ))}

        {ungrouped().length > 0 && (
          <View style={styles.groupSection}>
            <View style={styles.groupHeader}>
              <Text style={styles.groupName}>No group</Text>
              <Text style={styles.groupCount}>{ungrouped().length}</Text>
            </View>
            <View style={styles.groupList}>
              {ungrouped().map(renderSwimmerRow)}
            </View>
          </View>
        )}

        {groups.length === 0 && swimmers.length === 0 && !loading && (
          <View style={styles.emptyState}>
            <Text style={styles.emptyText}>No swimmers yet.</Text>
            <TouchableOpacity onPress={() => router.push("/swimmer-sheet")}>
              <Text style={styles.emptyAction}>+ Add your first swimmer</Text>
            </TouchableOpacity>
          </View>
        )}
      </ScrollView>
    </View>
  );
}

function AddGroupInline({
  onSubmit,
  onCancel,
}: {
  onSubmit: (name: string) => void;
  onCancel: () => void;
}) {
  const [name, setName] = useState("");
  return (
    <View style={styles.addGroupRow}>
      <TextInput
        style={styles.addGroupInput}
        value={name}
        onChangeText={setName}
        placeholder="Group name (e.g. Gold)"
        placeholderTextColor={Colors.dim}
        autoFocus
      />
      <TouchableOpacity
        style={styles.addGroupBtn}
        onPress={() => onSubmit(name)}
        disabled={!name.trim()}
      >
        <Text style={styles.addGroupBtnText}>Create</Text>
      </TouchableOpacity>
      <TouchableOpacity onPress={onCancel}>
        <Text style={styles.addGroupCancel}>Cancel</Text>
      </TouchableOpacity>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: Colors.base },
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: Space[6],
    paddingTop: Space[12],
    paddingBottom: Space[4],
    borderBottomWidth: 1,
    borderBottomColor: Colors.border,
  },
  screenLabel: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.xs,
    color: Colors.dim,
    letterSpacing: 1.2,
  },
  headerActions: { flexDirection: "row", gap: Space[2] },
  headerBtn: {
    backgroundColor: Colors.elevated,
    borderRadius: Radius.md,
    paddingHorizontal: Space[3],
    paddingVertical: Space[2],
    borderWidth: 1,
    borderColor: Colors.border,
  },
  headerBtnText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.cyan,
  },
  addGroupRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: Space[2],
    paddingHorizontal: Space[6],
    paddingVertical: Space[3],
    backgroundColor: Colors.surface,
    borderBottomWidth: 1,
    borderBottomColor: Colors.border,
  },
  addGroupInput: {
    flex: 1,
    backgroundColor: Colors.elevated,
    borderRadius: Radius.md,
    paddingHorizontal: Space[3],
    paddingVertical: Space[2],
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.text,
    borderWidth: 1,
    borderColor: Colors.border,
  },
  addGroupBtn: {
    backgroundColor: Colors.cyan,
    borderRadius: Radius.md,
    paddingHorizontal: Space[3],
    paddingVertical: Space[2],
  },
  addGroupBtnText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: "#000",
  },
  addGroupCancel: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
  },
  list: { flex: 1 },
  listContent: { paddingBottom: Space[8] },
  groupSection: { marginTop: Space[4] },
  groupHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: Space[6],
    marginBottom: Space[2],
  },
  groupName: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.sm,
    color: Colors.muted,
    letterSpacing: 0.5,
  },
  groupCount: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.xs,
    color: Colors.dim,
  },
  groupList: { borderTopWidth: 1, borderTopColor: Colors.border },
  swimmerRow: {
    flexDirection: "row",
    alignItems: "center",
    height: TouchTarget.swimRow,
    paddingHorizontal: Space[6],
    gap: Space[3],
  },
  initialsCircle: {
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: Colors.elevated,
    borderWidth: 1,
    borderColor: Colors.border,
    alignItems: "center",
    justifyContent: "center",
  },
  initialsText: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: 16,
    color: Colors.cyan,
  },
  swimmerName: {
    flex: 1,
    fontFamily: FontFamily.uiMedium,
    fontSize: FontSize.base,
    color: Colors.text,
  },
  chevron: {
    fontFamily: FontFamily.ui,
    fontSize: 20,
    color: Colors.border,
  },
  groupEmpty: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.sm,
    color: Colors.dim,
    paddingHorizontal: Space[6],
    paddingVertical: Space[2],
  },
  emptyState: {
    alignItems: "center",
    justifyContent: "center",
    paddingTop: Space[12],
    gap: Space[3],
  },
  emptyText: {
    fontFamily: FontFamily.ui,
    fontSize: FontSize.base,
    color: Colors.dim,
  },
  emptyAction: {
    fontFamily: FontFamily.uiSemiBold,
    fontSize: FontSize.base,
    color: Colors.cyan,
  },
});
