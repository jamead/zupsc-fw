-- Behavioral ADC model for simulation only (VHDL-2008).
-- Assumes LTC2376-20 normal mode: CHAIN=0, RDL/SDI=0, DGC disabled.
-- The output named sdi connects to the FPGA serial-data input;
-- it corresponds to the real ADC's SDO pin.
-- Reference: https://www.analog.com/media/en/technical-documentation/data-sheets/237620fb.pdf
--
-- On CNV rising: sample a continuous sine wave using simulation time.
-- After T_CONV: present the MSB. Capture it on the FIRST rising SCLK.
-- Each rising SCLK advances to the next bit after T_SDO; capture all
-- 20 bits on rising edges BEFORE that delay (ordinary FPGA clocked logic).
-- After bit 0 the model drives zero. Wait T_CONV + T_MSB before reading.
-- No reset is required. Initial output is zero; conversion output is X.
--
-- Simplifications: ideal quantization; no noise, DGC, daisy chain or
-- output-enable control. BUSY changes without pin propagation delay.
-- Only conversion overlap, 4 us cycle time and early reads are checked;
-- this is a functional model, not a complete datasheet timing checker.
--
-- Example testbench instantiation:
-- adc : entity work.ltc2376_sine_model
--   port map (cnv => adc_cnv, sclk => adc_sclk,
--             sdi => adc_sdi, busy => open);
-- Drive CNV every 4 us or slower. With default timing, start SCLK after
-- 3.005 us. A 25 MHz SCLK reads 20 bits in 800 ns.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity ltc2376_sine_model is
  generic (
    SINE_HZ      : real := 1000.0;
    AMPLITUDE_FS : real := 0.9;  -- peak as fraction of positive full scale
    OFFSET_FS    : real := 0.0;
    PHASE_DEG    : real := 0.0;  -- phase at simulation time zero
    T_CONV       : time := 3 us; -- datasheet maximum conversion time
    T_MSB        : time := 5 ns;
    T_SDO        : time := 8 ns
  );
  port (
    cnv  : in  std_logic;
    sclk : in  std_logic;
    sdi  : out std_logic := '0';
    busy : out std_logic := '0'
  );
end entity;

architecture behavioral of ltc2376_sine_model is
  signal conversion_done : boolean := false;
begin
  assert SINE_HZ > 0.0 and T_CONV > 0 ns and
         T_MSB >= 0 ns and T_SDO > 0 ns
    report "Invalid sine frequency or timing generic" severity failure;

  model : process(cnv, sclk, conversion_done)
    variable converting : boolean := false;
    variable have_data  : boolean := false;
    variable pending    : std_logic_vector(19 downto 0) := (others => '0');
    variable word       : std_logic_vector(19 downto 0) := (others => '0');
    variable bit_index  : integer range 0 to 19 := 19;
    variable last_cnv   : time := 0 ns;
    variable seen_cnv   : boolean := false;
    variable seconds   : real;
    variable value_fs  : real;
    variable code      : integer;
  begin
    if rising_edge(cnv) then
      if converting then
        assert false report "CNV during conversion: ignored" severity warning;
      else
        if seen_cnv then
          assert now - last_cnv >= 4 us
            report "LTC2376-20 CNV period is below 4 us" severity warning;
        end if;
        seen_cnv := true;
        last_cnv := now;
        -- Scale time in small units before converting to real seconds.
        -- This avoids overflowing an integer with now / 1 fs.
        seconds := real(now / 1 us) * 1.0e-6 +
                   real((now - (now / 1 us) * 1 us) / 1 ns) * 1.0e-9;
        value_fs := OFFSET_FS + AMPLITUDE_FS *
          sin(2.0 * MATH_PI * SINE_HZ * seconds +
              PHASE_DEG * MATH_PI / 180.0);
        -- Clamp BEFORE converting to integer to handle overrange safely.
        if value_fs >= 524287.0 / 524288.0 then
          code := 524287;
        elsif value_fs <= -1.0 then
          code := -524288;
        else
          code := integer(round(value_fs * 524288.0));
        end if;
        pending := std_logic_vector(to_signed(code, 20));
        converting := true;
        have_data := false;
        busy <= '1';
        sdi <= 'X';
        conversion_done <= not conversion_done after T_CONV;
      end if;
    elsif conversion_done'event then
      converting := false;
      have_data := true;
      word := pending;
      bit_index := 19;
      busy <= '0';
      sdi <= word(19) after T_MSB;
    elsif rising_edge(sclk) then
      if converting then
        assert false report "SCLK during conversion: ignored" severity warning;
      elsif have_data then
        if bit_index > 0 then
          bit_index := bit_index - 1;
          sdi <= word(bit_index) after T_SDO;
        else
          sdi <= '0' after T_SDO;
          have_data := false;
        end if;
      end if;
    end if;
  end process;
end architecture;
