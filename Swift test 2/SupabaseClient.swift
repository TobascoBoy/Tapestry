import Foundation
import Supabase

let supabase = SupabaseClient(
    supabaseURL: URL(string: "https://jrdikjncaxdzxmxcddjv.supabase.co")!,
    supabaseKey: "sb_publishable_I0bLlOuMPBw81zWPyI5RuQ_zM7WC1LN",
    options: .init(
        auth: .init(
            redirectToURL: URL(string: "tapestry://auth/callback")
        )
    )
)
