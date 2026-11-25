create or replace function admin_set_setting(p_key text, p_value text) returns void language plpgsql security definer set search_path = public as $$
declare n numeric; lim int;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_key = 'banner' then
    if char_length(coalesce(p_value, '')) > 200 then raise exception 'Banner is limited to 200 characters'; end if;
  elsif p_key in ('tagline','promo_title','promo_text') then
    lim := 200;
    if p_key = 'tagline' then lim := 120; end if;
    if p_key = 'promo_title' then lim := 80; end if;
    if char_length(coalesce(p_value, '')) > lim then raise exception 'That text is too long'; end if;
  elsif p_key in ('hero_image_url','img_promo','img_prices','img_auth','img_cat_grains','img_cat_vegetables','img_cat_fruits','img_cat_tubers','img_cat_cash','img_cat_other') then
    if coalesce(p_value, '') <> '' and p_value !~ '^https://[^ ]{4,480}$' then raise exception 'Picture address must start with https://'; end if;
  elsif p_key in ('delivery_fee_ugx','platform_fee_pct','rider_share_pct','auto_release_hours') then
    begin n := p_value::numeric; exception when others then raise exception 'Value must be a number'; end;
    if p_key = 'delivery_fee_ugx' and (n < 0 or n > 50000) then raise exception 'Delivery fee must be 0 to 50,000'; end if;
    if p_key = 'platform_fee_pct' and (n < 0 or n > 20) then raise exception 'Platform fee must be 0 to 20 percent'; end if;
    if p_key = 'rider_share_pct' and (n < 0 or n > 100) then raise exception 'Rider share must be 0 to 100 percent'; end if;
    if p_key = 'auto_release_hours' and (n < 1 or n > 720 or n <> trunc(n)) then raise exception 'Auto-release must be a whole number of hours from 1 to 720'; end if;
  else raise exception 'Unknown setting'; end if;
  insert into site_settings(key, value) values (p_key, coalesce(p_value, '')) on conflict (key) do update set value = excluded.value, updated_at = now();
  perform log_action('setting_' || p_key, null);
end $$;