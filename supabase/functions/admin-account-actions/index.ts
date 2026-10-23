import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, x-client-info, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, 'Content-Type': 'application/json' },
})

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (request.method !== 'POST') return json({ error: 'Método não permitido.' }, 405)

  try {
    const authorization = request.headers.get('Authorization')
    if (!authorization?.startsWith('Bearer ')) return json({ error: 'Sessão ausente.' }, 401)

    const projectUrl = Deno.env.get('SUPABASE_URL')
    const publishableKeys = JSON.parse(Deno.env.get('SUPABASE_PUBLISHABLE_KEYS') || '{}')
    const secretKeys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}')
    const publishableKey = publishableKeys.default
    const secretKey = secretKeys.default
    if (!projectUrl || !publishableKey || !secretKey) {
      return json({ error: 'Configuração administrativa indisponível no servidor.' }, 500)
    }

    const userClient = createClient(projectUrl, publishableKey, {
      global: { headers: { Authorization: authorization } },
      auth: { autoRefreshToken: false, persistSession: false },
    })
    const { data: authData, error: authError } = await userClient.auth.getUser()
    if (authError || !authData.user) return json({ error: 'Sessão inválida ou expirada.' }, 401)

    const { data: access, error: accessError } = await userClient.rpc('admin_access_status')
    if (accessError) return json({ error: 'Não foi possível validar o acesso administrativo.' }, 403)
    if (!access?.can_manage_admins) return json({ error: 'Apenas o administrador principal pode gerenciar contas.' }, 403)

    const { action, targetUserId } = await request.json()
    if (!['status', 'ban', 'unban', 'reset'].includes(action)) return json({ error: 'Ação inválida.' }, 400)
    if (typeof targetUserId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(targetUserId)) {
      return json({ error: 'Conta selecionada inválida.' }, 400)
    }
    if (targetUserId === authData.user.id) return json({ error: 'A conta administrativa atual está protegida.' }, 400)

    const adminClient = createClient(projectUrl, secretKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    })
    const { data: targetAdmin, error: targetAdminError } = await adminClient
      .from('game_admins')
      .select('user_id')
      .eq('user_id', targetUserId)
      .maybeSingle()
    if (targetAdminError) return json({ error: 'Não foi possível validar a conta selecionada.' }, 500)
    if (targetAdmin) return json({ error: 'Contas administrativas estão protegidas.' }, 400)

    if (action === 'reset') {
      const { data, error } = await userClient.rpc('admin_reset_trainer_progress', { p_target: targetUserId })
      if (error) return json({ error: error.message || 'Não foi possível resetar o progresso.' }, 400)
      const { error: signOutError } = await adminClient.auth.admin.signOut(targetUserId, 'global')
      return json({ ok: true, action, trainerName: data?.trainer_name, sessionsRevoked: !signOutError })
    }

    const { data: targetData, error: targetError } = await adminClient.auth.admin.getUserById(targetUserId)
    if (targetError || !targetData.user) return json({ error: 'Conta de login não encontrada.' }, 404)
    const bannedUntil = targetData.user.banned_until ? Date.parse(targetData.user.banned_until) : 0
    const isBanned = Number.isFinite(bannedUntil) && bannedUntil > Date.now()

    if (action === 'status') return json({ ok: true, isBanned, bannedUntil: isBanned ? targetData.user.banned_until : null })
    if (action === 'ban' && isBanned) return json({ ok: true, action, isBanned: true, alreadyApplied: true })
    if (action === 'unban' && !isBanned) return json({ ok: true, action, isBanned: false, alreadyApplied: true })

    const { error: updateError } = await adminClient.auth.admin.updateUserById(targetUserId, {
      ban_duration: action === 'ban' ? '876000h' : 'none',
    })
    if (updateError) return json({ error: updateError.message || 'Não foi possível alterar o acesso da conta.' }, 400)

    let sessionsRevoked = false
    if (action === 'ban') {
      const { error: signOutError } = await adminClient.auth.admin.signOut(targetUserId, 'global')
      sessionsRevoked = !signOutError
    }
    return json({ ok: true, action, isBanned: action === 'ban', sessionsRevoked })
  } catch (error) {
    console.error('[admin-account-actions]', error)
    return json({ error: error instanceof Error ? error.message : 'Falha inesperada no servidor.' }, 500)
  }
})
