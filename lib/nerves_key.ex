defmodule NervesKey do
  @moduledoc """
  This is a high level interface to provisioning and using the NervesKey
  or any ATECC508A/608A that can be configured similarly.
  """

  alias NervesKey.{Config, OTP, Data, ProvisioningInfo}

  @build_year DateTime.utc_now().year
  @settings_slots [8, 7, 6, 5]
  @settings_max_length Enum.reduce(@settings_slots, 0, fn slot, acc ->
                         acc + ATECC508A.DataZone.slot_size(slot)
                       end)

  @typedoc "Which device/signer certificate pair to use"
  @type certificate_pair() :: :primary | :aux

  @doc """
  Detect if a NervesKey is available on the transport
  """
  @spec detected?(ATECC508A.Transport.t()) :: boolean()
  defdelegate detected?(transport), to: ATECC508A.Transport

  @doc """
  Check whether the NervesKey has been provisioned
  """
  @spec provisioned?(ATECC508A.Transport.t()) :: boolean()
  def provisioned?(transport) do
    {:ok, config} = ATECC508A.Configuration.read(transport)

    # If the OTP and data sections are locked, then this chip has been provisioned.
    config.lock_value == 0
  end

  @doc """
  Create a signing key pair

  This returns a tuple that contains a new signer certificate and private key.
  It is compatible with the ATECC508A certificate compression.

  Options:

  * :years_valid - how many years this signing key is valid for
  """
  @spec create_signing_key_pair(keyword()) :: {X509.Certificate.t(), X509.PrivateKey.t()}
  def create_signing_key_pair(opts \\ []) do
    years_valid = Keyword.get(opts, :years_valid, 1)
    ATECC508A.Certificate.new_signer(years_valid)
  end

  @doc """
  Read the manufacturer's serial number
  """
  @spec manufacturer_sn(ATECC508A.Transport.t()) :: binary()
  def manufacturer_sn(transport) do
    {:ok, %OTP{manufacturer_sn: serial_number}} = OTP.read(transport)
    serial_number
  end

  @doc """
  Read the device certificate from the slot

  The device must be programmed for this to work.
  """
  @spec device_cert(ATECC508A.Transport.t(), certificate_pair()) :: X509.Certificate.t()
  def device_cert(transport, which \\ :primary) do
    {:ok, device_sn} = Config.device_sn(transport)
    {:ok, device_data} = ATECC508A.DataZone.read(transport, Data.device_cert_slot(which))

    {:ok, <<signer_public_key_raw::64-bytes, _pad::8-bytes>>} =
      ATECC508A.DataZone.read(transport, Data.signer_pubkey_slot(which))

    signer_public_key = ATECC508A.Certificate.raw_to_public_key(signer_public_key_raw)
    {:ok, %OTP{manufacturer_sn: serial_number}} = OTP.read(transport)
    {:ok, public_key_raw} = Data.genkey_raw(transport, false)

    template = ATECC508A.Certificate.Template.device(serial_number, signer_public_key)

    compressed = %ATECC508A.Certificate.Compressed{
      data: device_data,
      device_sn: device_sn,
      public_key: public_key_raw,
      template: template,
      issuer_rdn: X509.RDNSequence.new("/CN=Signer", :otp),
      subject_rdn: X509.RDNSequence.new("/CN=" <> serial_number, :otp)
    }

    ATECC508A.Certificate.decompress(compressed)
  end

  @doc """
  Read the signer certificate from the slot
  """
  @spec signer_cert(ATECC508A.Transport.t(), certificate_pair()) :: X509.Certificate.t()
  def signer_cert(transport, which \\ :primary) do
    {:ok, signer_data} = ATECC508A.DataZone.read(transport, Data.signer_cert_slot(which))

    {:ok, <<signer_public_key_raw::64-bytes, _pad::8-bytes>>} =
      ATECC508A.DataZone.read(transport, Data.signer_pubkey_slot(which))

    signer_public_key = ATECC508A.Certificate.raw_to_public_key(signer_public_key_raw)
    template = ATECC508A.Certificate.Template.signer(signer_public_key)

    compressed = %ATECC508A.Certificate.Compressed{
      data: signer_data,
      public_key: signer_public_key_raw,
      template: template,
      issuer_rdn: X509.RDNSequence.new("/CN=Signer", :otp),
      subject_rdn: X509.RDNSequence.new("/CN=Signer", :otp)
    }

    ATECC508A.Certificate.decompress(compressed)
  end

  @doc """
  Provision a NervesKey in one step.

  See the README.md for how to use this. This function locks the
  ATECC508A down, so you'll want to be sure what you pass it is
  correct.

  This function does it all. It requires the signer's private key so
  handle that with care. Alternatively, please consider sending a PR
  for supporting off-device signatures so that HSMs can be used.
  """
  @spec provision(
          ATECC508A.Transport.t(),
          ProvisioningInfo.t(),
          X509.Certificate.t(),
          X509.PrivateKey.t()
        ) :: :ok
  def provision(transport, info, signer_cert, signer_key) do
    check_time()

    :ok = configure(transport)
    otp_info = OTP.new(info.board_name, info.manufacturer_sn)
    otp_data = OTP.to_raw(otp_info)
    :ok = OTP.write(transport, otp_data)

    {:ok, device_public_key} = Data.genkey(transport)
    {:ok, device_sn} = Config.device_sn(transport)

    device_cert =
      ATECC508A.Certificate.new_device(
        device_public_key,
        device_sn,
        info.manufacturer_sn,
        signer_cert,
        signer_key
      )

    slot_data = Data.slot_data(device_sn, device_cert, signer_cert)

    :ok = Data.write_slots(transport, slot_data)

    # This is the point of no return!!

    # Lock the data and OTP zones
    :ok = Data.lock(transport, otp_data, slot_data)

    # Lock the slot that contains the private key to prevent calls to GenKey
    # from changing it. See datasheet for how GenKey doesn't check the zone
    # lock.
    :ok = ATECC508A.Request.lock_slot(transport, 0)
  end

  @doc """
  Provision the auxiliary device/signer certificates on a NervesKey.

  This function creates and saves the auxiliary certificates. These
  are only needed if the ones written by `provision/4` are not
  usable. They are not used unless explicitly requested. See the
  README.md for details.

  You may call this function multiple times after the ATECC508A
  has been provisioned.
  """
  @spec provision_aux_certificates(
          ATECC508A.Transport.t(),
          X509.Certificate.t(),
          X509.PrivateKey.t()
        ) :: :ok
  def provision_aux_certificates(transport, signer_cert, signer_key) do
    check_time()

    manufacturer_sn = manufacturer_sn(transport)
    {:ok, device_public_key} = Data.genkey(transport, false)
    {:ok, device_sn} = Config.device_sn(transport)

    device_cert =
      ATECC508A.Certificate.new_device(
        device_public_key,
        device_sn,
        manufacturer_sn,
        signer_cert,
        signer_key
      )

    Data.write_aux_certs(transport, device_sn, device_cert, signer_cert)
  end

  @doc """
  Clear out the auxiliary certificates

  This function overwrites the auxiliary certificate slots with
  """
  @spec clear_aux_certificates(ATECC508A.Transport.t()) :: :ok
  def clear_aux_certificates(transport) do
    Data.clear_aux_certs(transport)
  end

  @doc """
  Check whether the auxiliary certificates were programmed
  """
  @spec has_aux_certificates?(ATECC508A.Transport.t()) :: boolean()
  def has_aux_certificates?(transport) do
    slot = Data.device_cert_slot(:aux)
    slot_size = ATECC508A.DataZone.slot_size(slot)
    {:ok, slot_contents} = ATECC508A.DataZone.read(transport, slot)
    slot_contents != <<0::size(slot_size)-unit(8)>>
  end

  @doc """
  Return default provisioning info for a NervesKey

  This function is used for pre-programmed NervesKey devices. The
  serial number is a Base32-encoded version of the ATECC508A/608A's globally unique
  serial number. No additional care is needed to keep the number unique.
  """
  @spec default_info(ATECC508A.Transport.t()) :: ProvisioningInfo.t()
  def default_info(transport) do
    {:ok, sn} = Config.device_sn(transport)

    %ProvisioningInfo{manufacturer_sn: Base.encode32(sn, padding: false), board_name: "NervesKey"}
  end

  @doc """
  Return the settings block as a binary
  """
  @spec get_raw_settings(ATECC508A.Transport.t()) :: {:ok, binary()} | {:error, atom()}
  def get_raw_settings(transport) do
    all_reads = Enum.map(@settings_slots, &ATECC508A.DataZone.read(transport, &1))

    case Enum.find(all_reads, fn {result, _} -> result != :ok end) do
      nil ->
        raw = Enum.map_join(all_reads, fn {:ok, contents} -> contents end)
        {:ok, raw}

      error ->
        error
    end
  end

  @doc """
  Return all of the setting stored in the NervesKey as a map
  """
  @spec get_settings(ATECC508A.Transport.t()) :: {:ok, map()} | {:error, atom()}
  def get_settings(transport) do
    with {:ok, raw_settings} <- get_raw_settings(transport) do
      try do
        settings = :erlang.binary_to_term(raw_settings, [:safe])
        {:ok, settings}
      catch
        _, _ -> {:error, :corrupt}
      end
    end
  end

  @doc """
  Store settings on the NervesKey

  This overwrites all of the settings that are currently on the key and should
  be used with care since there's no protection against a race condition with
  other NervesKey users.
  """
  @spec put_settings(ATECC508A.Transport.t(), map()) :: :ok
  def put_settings(transport, settings) when is_map(settings) do
    raw_settings = :erlang.term_to_binary(settings)
    put_raw_settings(transport, raw_settings)
  end

  @doc """
  Store raw settings on the Nerves Key

  This overwrites all of the settings and should be used with care since there's
  no protection against race conditions with other users of this API.
  """
  @spec put_raw_settings(ATECC508A.Transport.t(), binary()) :: :ok
  def put_raw_settings(transport, raw_settings) when is_binary(raw_settings) do
    if byte_size(raw_settings) > @settings_max_length do
      raise "Settings are too large and won't fit in the NervesKey. The max raw size is #{
              @settings_max_length
            }."
    end

    padded_settings = pad(raw_settings, @settings_max_length)
    slots = break_into_slots(padded_settings, @settings_slots)

    Enum.each(slots, fn {slot, data} -> ATECC508A.DataZone.write(transport, slot, data) end)
  end

  defp pad(bin, len) when byte_size(bin) < len do
    to_pad = 8 * (len - byte_size(bin))
    <<bin::binary, 0::size(to_pad)>>
  end

  defp pad(bin, _len), do: bin

  defp break_into_slots(bin, slots) do
    break_into_slots(bin, slots, [])
    |> Enum.reverse()
  end

  defp break_into_slots(<<>>, [], result), do: result

  defp break_into_slots(bin, [slot | rest], result) do
    slot_len = ATECC508A.DataZone.slot_size(slot)
    {contents, next} = :erlang.split_binary(bin, slot_len)
    break_into_slots(next, rest, [{slot, contents} | result])
  end

  # Configure an ATECC508A or ATECC608A as a NervesKey.
  #
  # This is called from `provision/4`. It can be called multiple
  # times and so long as the part is configured in a compatible
  # way, then it succeeds. This is needed to recover from failures
  # in the provisioning process.
  defp configure(transport) do
    cond do
      Config.config_compatible?(transport) == {:ok, true} -> :ok
      Config.configured?(transport) == {:ok, true} -> {:error, :config_locked}
      true -> Config.configure(transport)
    end
  end

  defp check_time() do
    unless DateTime.utc_now().year >= @build_year do
      raise """
      It doesn't look like the clock has been set. Check that `nerves_time` is running
      or something else is providing time.
      """
    end
  end
end
