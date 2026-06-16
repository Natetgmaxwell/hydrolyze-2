/**
 * Swimmers module — CRUD helpers for roster management.
 */

import { supabase } from "./supabase";

export interface Swimmer {
  id: string;
  coach_id: string;
  first_name: string;
  last_name: string | null;
  birthdate: string | null;
  gender: string | null;
  notes: string | null;
  archived_at: string | null;
  created_at: string;
  groups: { id: string; name: string }[];
}

export interface Group {
  id: string;
  name: string;
}

/** Build initials from first + last name */
export function getInitials(
  firstName: string,
  lastName?: string | null,
): string {
  if (firstName && lastName) {
    return (firstName[0] + lastName[0]).toUpperCase();
  }
  if (firstName) return firstName.slice(0, 2).toUpperCase();
  return "?";
}

/** Get all active swimmers for a coach with their groups */
export async function getSwimmers(coachId: string): Promise<Swimmer[]> {
  const { data: swimmers } = await supabase
    .from("swimmers")
    .select(
      "id, coach_id, first_name, last_name, birthdate, gender, notes, archived_at, created_at",
    )
    .eq("coach_id", coachId)
    .is("archived_at", null)
    .order("last_name", { ascending: true })
    .order("first_name", { ascending: true });

  if (!swimmers?.length) return [];

  const swimmerIds = swimmers.map((s) => s.id);

  const [{ data: memberships }, { data: groupsData }] = await Promise.all([
    supabase
      .from("swimmer_groups")
      .select("swimmer_id, group_id")
      .in("swimmer_id", swimmerIds),
    supabase
      .from("groups")
      .select("id, name")
      .eq("coach_id", coachId)
      .order("name"),
  ]);

  const groupMap: Record<string, { id: string; name: string }[]> = {};
  for (const m of memberships ?? []) {
    if (!groupMap[m.swimmer_id]) groupMap[m.swimmer_id] = [];
    const g = groupsData?.find((g) => g.id === m.group_id);
    if (g) groupMap[m.swimmer_id].push(g);
  }

  return swimmers.map((s) => ({
    ...s,
    groups: groupMap[s.id] ?? [],
  }));
}

/** Get all groups for a coach */
export async function getGroups(coachId: string): Promise<Group[]> {
  const { data } = await supabase
    .from("groups")
    .select("id, name")
    .eq("coach_id", coachId)
    .order("name");
  return data ?? [];
}

/** Create a swimmer and optionally assign to groups */
export async function createSwimmer({
  coachId,
  firstName,
  lastName,
  birthdate,
  gender,
  notes,
  groupIds = [],
}: {
  coachId: string;
  firstName: string;
  lastName?: string | null;
  birthdate?: string | null;
  gender?: string | null;
  notes?: string | null;
  groupIds?: string[];
}): Promise<string> {
  const { data: swimmer, error: swimmerErr } = await supabase
    .from("swimmers")
    .insert({
      coach_id: coachId,
      first_name: firstName,
      last_name: lastName ?? null,
      birthdate: birthdate ?? null,
      gender: gender ?? null,
      notes: notes ?? null,
    })
    .select("id")
    .single();

  if (swimmerErr || !swimmer) {
    throw new Error(swimmerErr?.message ?? "Failed to create swimmer");
  }

  if (groupIds.length > 0) {
    const memberships = groupIds.map((groupId) => ({
      swimmer_id: swimmer.id,
      group_id: groupId,
    }));
    const { error: groupErr } = await supabase
      .from("swimmer_groups")
      .insert(memberships);

    if (groupErr)
      console.error("[swimmers] group assignment error:", groupErr.message);
  }

  return swimmer.id;
}

/** Update swimmer fields and reassign groups */
export async function updateSwimmer(
  swimmerId: string,
  fields: {
    firstName?: string;
    lastName?: string | null;
    birthdate?: string | null;
    gender?: string | null;
    notes?: string | null;
  },
  groupIds: string[],
): Promise<void> {
  const updateFields: Record<string, unknown> = {};
  if (fields.firstName !== undefined)
    updateFields.first_name = fields.firstName;
  if (fields.lastName !== undefined) updateFields.last_name = fields.lastName;
  if (fields.birthdate !== undefined) updateFields.birthdate = fields.birthdate;
  if (fields.gender !== undefined) updateFields.gender = fields.gender;
  if (fields.notes !== undefined) updateFields.notes = fields.notes;
  updateFields.updated_at = new Date().toISOString();

  const { error: updateErr } = await supabase
    .from("swimmers")
    .update(updateFields)
    .eq("id", swimmerId);

  if (updateErr) {
    throw new Error(updateErr.message);
  }

  await supabase.from("swimmer_groups").delete().eq("swimmer_id", swimmerId);

  if (groupIds.length > 0) {
    const memberships = groupIds.map((groupId) => ({
      swimmer_id: swimmerId,
      group_id: groupId,
    }));
    const { error: groupErr } = await supabase
      .from("swimmer_groups")
      .insert(memberships);

    if (groupErr)
      console.error("[swimmers] group reassignment error:", groupErr.message);
  }
}

/** Soft-delete a swimmer (preserves PB history) */
export async function deleteSwimmer(swimmerId: string): Promise<void> {
  const { error } = await supabase
    .from("swimmers")
    .update({ archived_at: new Date().toISOString() })
    .eq("id", swimmerId);

  if (error) throw new Error(error.message);
}

/** Create a group */
export async function createGroup(
  coachId: string,
  name: string,
): Promise<string> {
  const { data, error } = await supabase
    .from("groups")
    .insert({ coach_id: coachId, name })
    .select("id")
    .single();

  if (error || !data)
    throw new Error(error?.message ?? "Failed to create group");
  return data.id;
}

/** Delete a group (swimmer group memberships cascade) */
export async function deleteGroup(groupId: string): Promise<void> {
  const { error } = await supabase.from("groups").delete().eq("id", groupId);
  if (error) throw new Error(error.message);
}
