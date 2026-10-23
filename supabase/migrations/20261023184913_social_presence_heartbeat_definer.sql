-- O heartbeat só grava a linha identificada por auth.uid().
-- SECURITY DEFINER é necessário porque a leitura dos campos Pokémon foi
-- removida do acesso direto dos clientes.
alter function public.social_presence_with_pokemon(text, integer, text) security definer;
