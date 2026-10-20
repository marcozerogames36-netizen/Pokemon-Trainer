-- Adiciona um Scyther ao time de Marco Zero (ou ao PC se a equipe já tiver 6).
-- Execute uma única vez no SQL Editor do Supabase.
do $$
declare
  v_user_id uuid := '3387c3e3-9bd8-4f12-a7a3-6a30e59ad419';
  v_player jsonb;
  v_pokemon jsonb;
  v_boxes jsonb;
  v_box jsonb;
  v_level integer;
  v_hp integer;
  v_box_index integer;
  v_slot integer;
begin
  select player into v_player
  from public.game_saves
  where user_id = v_user_id
  for update;

  if not found then raise exception 'Não existe save para o UID informado.'; end if;
  if lower(trim(coalesce(v_player->>'name',''))) not in ('marco zero','marco zero games') then
    raise exception 'O nome do treinador do UID informado não corresponde a Marco Zero. Nenhuma alteração foi feita.';
  end if;
  if exists (
    select 1 from jsonb_array_elements(coalesce(v_player->'party','[]'::jsonb)) p(value)
    where (p.value->>'id')::integer = 123
  ) or exists (
    select 1 from jsonb_array_elements(coalesce(v_player->'pc'->'boxes','[]'::jsonb)) b(value)
    cross join lateral jsonb_array_elements(case when jsonb_typeof(b.value)='array' then b.value else '[]'::jsonb end) p(value)
    where (p.value->>'id')::integer = 123
  ) then
    raise exception 'Scyther já está no time ou no PC. Nenhuma alteração foi feita.';
  end if;

  select greatest(5,least(100,coalesce(round(avg((p.value->>'level')::numeric),0)::integer,38)))
    into v_level
  from jsonb_array_elements(coalesce(v_player->'party','[]'::jsonb)) p(value);
  v_hp := floor((2*70+15)*v_level/100.0)::integer + v_level + 10;

  v_pokemon := jsonb_build_object(
    'name','Scyther','id',123,'gender','male','type','Inseto/Voador','types',jsonb_build_array('Inseto','Voador'),
    'maxHp',v_hp,'hp',v_hp,'level',v_level,'nature','Adamant','ability','Swarm',
    'ivs',jsonb_build_object('hp',15,'attack',15,'defense',15,'specialAttack',15,'specialDefense',15,'speed',15),
    'evs',jsonb_build_object('hp',0,'attack',0,'defense',0,'specialAttack',0,'specialDefense',0,'speed',0),
    'stats',jsonb_build_object(
      'hp',v_hp,
      'attack',floor((2*110+15)*v_level/100.0)::integer+5,
      'defense',floor((2*80+15)*v_level/100.0)::integer+5,
      'specialAttack',floor((2*55+15)*v_level/100.0)::integer+5,
      'specialDefense',floor((2*80+15)*v_level/100.0)::integer+5,
      'speed',floor((2*105+15)*v_level/100.0)::integer+5
    ),
    'growthRate','mediumFast','exp',v_level*v_level*v_level,
    'moves',jsonb_build_array(
      jsonb_build_object('name','Quick Attack','type','Normal','power',40,'accuracy',100,'category','physical','priority',1,'pp',30,'maxPp',30),
      jsonb_build_object('name','Wing Attack','type','Voador','power',60,'accuracy',100,'category','physical','priority',0,'pp',35,'maxPp',35),
      jsonb_build_object('name','Slash','type','Normal','power',70,'accuracy',100,'category','physical','priority',0,'pp',20,'maxPp',20),
      jsonb_build_object('name','Swords Dance','type','Normal','power',0,'accuracy',100,'category','status','priority',0,'pp',20,'maxPp',20,
        'statChanges',jsonb_build_array(jsonb_build_object('target','self','stat','attack','stages',2)))
    ),
    'status','','heldItem','','tradeId',gen_random_uuid()::text,'shiny',false
  );

  if jsonb_array_length(coalesce(v_player->'party','[]'::jsonb)) < 6 then
    v_player := jsonb_set(v_player,'{party}',coalesce(v_player->'party','[]'::jsonb)||jsonb_build_array(v_pokemon),true);
  else
    v_boxes := v_player->'pc'->'boxes';
    if jsonb_typeof(v_boxes) is distinct from 'array' or jsonb_array_length(v_boxes) <> 8 then
      v_boxes := '[]'::jsonb;
      for v_box_index in 0..7 loop
        v_boxes := v_boxes || jsonb_build_array('[]'::jsonb);
      end loop;
    end if;

    for v_box_index in 0..7 loop
      v_box := case when jsonb_typeof(v_boxes->v_box_index)='array' then v_boxes->v_box_index else '[]'::jsonb end;
      select coalesce(jsonb_agg(case when n <= jsonb_array_length(v_box) then v_box->(n-1) else 'null'::jsonb end order by n),'[]'::jsonb)
        into v_box from generate_series(1,30) n;
      select (e.ordinality-1)::integer into v_slot
      from jsonb_array_elements(v_box) with ordinality e(value,ordinality)
      where e.value='null'::jsonb limit 1;
      if v_slot is not null then
        v_boxes := jsonb_set(v_boxes,array[v_box_index::text],v_box,true);
        v_boxes := jsonb_set(v_boxes,array[v_box_index::text,v_slot::text],v_pokemon,true);
        v_player := jsonb_set(v_player,'{pc}',coalesce(v_player->'pc','{}'::jsonb)||jsonb_build_object('boxes',v_boxes,'currentBox',v_box_index),true);
        exit;
      end if;
      v_slot := null;
    end loop;
    if v_slot is null then raise exception 'O PC está cheio. Nenhuma alteração foi feita.'; end if;
  end if;

  update public.game_saves set player=v_player,updated_at=now() where user_id=v_user_id;
end;
$$;
