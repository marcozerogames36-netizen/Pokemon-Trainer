-- Allow an administrator to clear every Pokemon from a selected trainer's party and PC.
create or replace function public.admin_remove_all_trainer_pokemon(p_target uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_player jsonb;
  v_party jsonb;
  v_boxes jsonb;
  v_cleared_boxes jsonb;
  v_pc jsonb;
  v_party_count integer;
  v_pc_count integer;
begin
  if not public.is_game_admin() then
    raise exception 'Acesso restrito ao administrador.';
  end if;
  if p_target is null then
    raise exception 'Selecione um treinador.';
  end if;

  select gs.player
    into v_player
    from public.game_saves as gs
   where gs.user_id = p_target
   for update;
  if not found then
    raise exception 'Save do treinador nao encontrado.';
  end if;

  v_party := case
    when jsonb_typeof(v_player->'party') = 'array' then v_player->'party'
    else '[]'::jsonb
  end;
  select count(*)::integer
    into v_party_count
    from jsonb_array_elements(v_party) as pokemon(value)
   where jsonb_typeof(pokemon.value) = 'object';

  v_boxes := case
    when jsonb_typeof(v_player#>'{pc,boxes}') = 'array' then v_player#>'{pc,boxes}'
    else '[]'::jsonb
  end;
  select count(*)::integer
    into v_pc_count
    from jsonb_array_elements(v_boxes) as box(value)
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(box.value) = 'array' then box.value else '[]'::jsonb end
    ) as slot(value)
   where jsonb_typeof(slot.value) = 'object';

  select coalesce(
    jsonb_agg(
      case
        when jsonb_typeof(box.value) = 'array' then (
          select coalesce(
            jsonb_agg(case when jsonb_typeof(slot.value) = 'object' then 'null'::jsonb else slot.value end order by slot.ordinality),
            '[]'::jsonb
          )
            from jsonb_array_elements(box.value) with ordinality as slot(value, ordinality)
        )
        else box.value
      end
      order by box.ordinality
    ),
    '[]'::jsonb
  )
    into v_cleared_boxes
    from jsonb_array_elements(v_boxes) with ordinality as box(value, ordinality);

  v_pc := case
    when jsonb_typeof(v_player->'pc') = 'object' then v_player->'pc'
    else '{}'::jsonb
  end;
  v_pc := jsonb_set(v_pc, '{boxes}', v_cleared_boxes, true);
  v_player := jsonb_set(v_player, '{party}', '[]'::jsonb, true);
  v_player := jsonb_set(v_player, '{pc}', v_pc, true);
  v_player := v_player - 'poke';

  update public.game_saves
     set player = v_player,
         updated_at = now()
   where user_id = p_target;

  return jsonb_build_object('user_id', p_target, 'party_count', v_party_count, 'pc_count', v_pc_count);
end;
$$;

revoke execute on function public.admin_remove_all_trainer_pokemon(uuid) from public, anon;
grant execute on function public.admin_remove_all_trainer_pokemon(uuid) to authenticated;
